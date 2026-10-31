// Mahi Stores frontend. No build step, no framework -- this runs
// unmodified off a static file mount so there's one less thing to break on
// stage.
//
// Event contract (produced by the agent / mahi-tools / OPA, relayed
// verbatim by the storefront, consumed here):
//   { type: "identity", spiffe_id, svid_expires_at, ttl_seconds, message }
//   { type: "denied", resource: "identity" | "policy" | <table/resource name>, message }
//     resource "identity"  -- Envoy Gateway's own JWT check refused this request
//     resource "policy"    -- OPA's extAuth refused it (wrong SPIFFE identity for this tool, etc.)
//     anything else        -- mahi-tools' own Postgres-GRANT or K8s-RBAC backstop refused it
//   { type: "scope_violation", resource, message }  -- insecure agent only: a query that SHOULD have been refused, wasn't
//   { type: "approval_required", order_id | replicas, amount_pence?, message }  -- OPA or mahi-tools decided this needs a human
//   { type: "approval_requested", approval_id, amount_pence, message }          -- the agent's own local pending-state
//   { type: "approval_granted", approval_id, approved_by, message }
//   { type: "refund_issued", order_id, amount_pence, message }
//   { type: "scale_applied", replicas, deployment, message }
//   { type: "info" | "error", message }
// Every event also carries `ts` (epoch seconds), added by the storefront if
// the agent didn't set one.

// The Agentic Workflow tab's stage graph: a dark stage-column diagram
// (Identity -> Gateway -> Policy -> Approval -> Execute), each column
// holding one or more real actor-cards, with a pulse that travels
// card-to-card as real events arrive (see playTurnAnimation below). One
// source of truth for both the graph and the detail drawer -- content
// lives here, not in index.html. A card's `eventTypes` is what actually
// lights it up; no card is faked active by a timer. Identity's cards are
// the exception -- they're also kept live by polling /api/state's
// per-agent status (see pollState), so both registered agents show real
// data even before any message is sent, not just whichever one answered
// the last turn.
const STAGES = [
  {
    id: "identity", num: 1, label: "Identity", icon: "🪪",
    what: "SPIRE issues the handling agent pod a short-lived JWT-SVID over the SPIFFE Workload API, written to disk by the spiffe-helper sidecar. order-agent and refund-agent are two genuinely separate identities -- not one agent with a mode switch -- each with its own ServiceAccount and ClusterSPIFFEID. The legacy agent skips this step entirely: no identity, just a password baked into its environment.",
    why: "A real workload identity exists before the agent ever calls the gateway -- it isn't minted on the fly or typed in by anyone. Both agents exist whether or not this turn used them. This identity itself expires (300s) -- there is no credential to separately revoke.",
    tags: ["SPIRE", "JWT-SVID", "ClusterSPIFFEID"],
    cards: [
      { id: "order-agent", agentKey: "order", label: "order-agent", icon: "🤖", sub: "read-only", modes: ["secure"] },
      { id: "refund-agent", agentKey: "refund", label: "refund-agent", icon: "🤖", sub: "can refund", modes: ["secure"] },
      { id: "legacy-agent", agentKey: "insecure", label: "Legacy Agent", icon: "🤖", sub: "static password", modes: ["insecure"] },
    ],
  },
  {
    id: "gateway", num: 2, label: "Gateway", icon: "🚪",
    what: "Every call to mahi-tools goes through Envoy Gateway first. Its SecurityPolicy validates the SVID's signature against SPIRE's own rotating JWKS (fetched live, not a static bundle) and checks the `aud` claim -- an expired, forged, or wrong-audience token is refused here, before OPA or mahi-tools ever see the request. The legacy agent has no equivalent step: a static password connects straight to Postgres.",
    why: "No password, no API key -- identity is the credential, and it's verified on every single call, not once at login.",
    tags: ["Envoy Gateway", "SecurityPolicy", "JWT"],
    cards: [{ id: "envoy-gateway", label: "Envoy Gateway", icon: "🚪", sub: "JWT verification" }],
  },
  {
    id: "policy", num: 3, label: "Policy", icon: "⚖️", eventTypes: ["approval_required"],
    what: "OPA decides whether this verified identity may call this exact tool path at all -- order-agent is refused on POST /tools/issue_refund outright, regardless of whatever Postgres privilege its login role happens to hold right now (that's beat 4's point). For scale_deployment, OPA also gates the replica count itself. Refund amount is the one decision OPA deliberately does NOT make -- it has no database access, so that call is mahi-tools', informed by the order's real total.",
    why: "Bind every tool call to policy, not just a login. Widening a Postgres role in Git does not change this rule -- identity and request shape are what's evaluated, every time.",
    tags: ["OPA", "Rego", "ext_authz"],
    cards: [{ id: "opa-policy", label: "OPA", icon: "⚖️", sub: "ext_authz" }],
  },
  {
    id: "approval", num: 4, label: "Approval", icon: "🧑‍⚖️",
    eventTypes: ["approval_requested", "approval_granted"],
    what: "Refunds over £100 (and scale requests over a small replica ceiling) pause here for a human to approve. The approval card is populated from a human identity the presenter cached once (scripts/presenter-login.sh) -- not a free-text box. Approving forwards that name to mahi-tools as a plain, recorded X-Approved-By header; it is NOT cryptographically verified (no Vault OBO in this build), an honest simplification said plainly if asked. Under the threshold, this stage is bypassed entirely -- shown as a bypass arc, not skipped silently.",
    why: "The action and the authorization are the same auditable event -- recorded in the refunds row itself (issued_by, approved_by, correlation_id), not two separate logs to correlate by hand.",
    tags: ["human-in-the-loop", "X-Approved-By"],
    cards: [{ id: "approval-card", label: "Approval", icon: "🧑‍⚖️", sub: "human sign-off" }],
  },
  {
    id: "execute", num: 5, label: "Execute", icon: "🗄️", eventTypes: ["refund_issued", "scale_applied", "scope_violation"],
    what: "mahi-tools runs the action as a least-privileged Postgres login role (joined to mahi_order_grp or mahi_refund_grp -- see k8s/cnpg/cluster.yaml) or against the Kubernetes API with RBAC narrowed to one Deployment's scale subresource. Ask for something outside scope (another customer's PII, a refund the role has no grant for) and Postgres itself refuses it, the same mechanism every time -- the last line of defence underneath Gateway and Policy, not a substitute for them.",
    why: "The boundary is enforced by the database's own grants and Kubernetes' own RBAC -- not a special case in anyone's code that someone could forget to add.",
    tags: ["PostgreSQL GRANTs", "Kubernetes RBAC"],
    cards: [{ id: "database", label: "Database / K8s", icon: "🗄️", sub: "mahi-tools" }],
  },
];
// Flat list of every card across every stage -- the unit the graph/pulse
// actually operates on (a stage is just how cards are grouped visually).
const CARDS = STAGES.flatMap((s) => s.cards.map((c) => ({ ...c, stageId: s.id })));
const CARD_BY_TYPE = {};
for (const s of STAGES) for (const t of s.eventTypes || []) {
  // Non-identity stages have exactly one card; events light that card.
  CARD_BY_TYPE[t] = s.cards[0].id;
}

const state = {
  customerId: 1,
  agent: "secure",
  identity: null,       // last identity event
  activeAgent: null,     // "order" | "refund" -- which identity card handled the last turn
  agentStatus: { order: null, refund: null, insecure: null }, // live /api/state polling, see pollState
  correlation: null,     // last approval_granted's {approved_by, spiffe_id, action, ts} -- NOT cleared later, see applyEvents
  anyActivity: false,    // has at least one real event happened this run
  cardEvents: Object.fromEntries(CARDS.map((c) => [c.id, []])),
  openStage: null,        // which card's detail drawer is open, if any
  pendingApproval: null, // {approval_id, thread_id}
  threadId: "demo",
};

function _agentKeyFromSpiffeId(spiffeId) {
  if (!spiffeId) return null;
  const sa = spiffeId.split("/").pop();
  if (sa === "ai-order-agent") return "order";
  if (sa === "ai-support-agent-secure") return "refund";
  return null;
}

const $ = (id) => document.getElementById(id);

async function j(method, url, body) {
  const r = await fetch(url, {
    method,
    headers: body ? { "Content-Type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!r.ok) throw new Error(`${method} ${url} -> ${r.status}`);
  return r.json();
}

function money(pence) {
  return `£${(pence / 100).toFixed(2)}`;
}

function fmtTime(ts) {
  return new Date(ts * 1000).toLocaleTimeString([], { hour12: false });
}

// ---------- catalog ----------

// Real product photos (Wikimedia Commons, freely licensed -- see
// static/images/ATTRIBUTION.md), bundled locally and served as static
// files -- not hotlinked to an external host. Keyed by a keyword matched
// against the product name, not product_id, so new catalog rows pick up a
// sensible image for free. Local, not a live external URL: nothing to
// fail to load if the venue Wi-Fi drops mid-talk.
const PRODUCT_IMAGES = {
  headphone: "headphones.jpg",
  keyboard: "keyboard.jpg",
  monitor: "monitor.png",
  charger: "charger.jpg",
  mouse: "mouse.jpg",
  stand: "stand.jpg",
  webcam: "webcam.jpg",
  speaker: "speaker.jpg",
  sleeve: "sleeve.jpg",
  hub: "hub.jpg",
  iphone: "iphone.jpg",
  macbook: "macbook.jpg",
  airpods: "airpods.jpg",
  watch: "applewatch.jpg",
};

function _imageFor(name) {
  const lower = name.toLowerCase();
  for (const [keyword, file] of Object.entries(PRODUCT_IMAGES)) {
    if (lower.includes(keyword)) return `/static/images/${file}`;
  }
  return null;
}

async function loadCustomers() {
  const customers = await j("GET", "/api/customers");
  // Two pickers, same options -- the Agentic Workflow tab's (demo-controls)
  // and the one inside the chat widget itself, so a real visitor never
  // has to leave the chat to say who they are.
  for (const sel of [$("customer-picker"), $("chat-customer-picker")]) {
    sel.innerHTML = "";
    for (const c of customers) {
      const opt = document.createElement("option");
      opt.value = c.customer_id;
      opt.textContent = c.name;
      sel.appendChild(opt);
    }
    sel.value = state.customerId;
  }
}

async function loadProducts() {
  const products = await j("GET", "/api/products");
  const grid = $("products");
  grid.innerHTML = "";
  for (const p of products) {
    const card = document.createElement("div");
    card.className = "product-card";
    const imgSrc = _imageFor(p.name);
    const imageHtml = imgSrc
      ? `<img src="${imgSrc}" alt="${p.name}" loading="lazy" />`
      : "";
    card.innerHTML = `
      <div class="product-image">${imageHtml}</div>
      <div class="product-body">
        <div class="name">${p.name}</div>
        <div class="description">${p.description}</div>
        <div class="price">${money(p.price_pence)}</div>
      </div>`;
    grid.appendChild(card);
  }
}

// Presenter reference: who ordered what, with the order number -- lives
// in the Agentic Workflow tab only (see index.html's comment), reusing the
// same /api/orders data the backend already serves. Refreshed on load and
// after a reset, since a reset reverts any refunds back to their
// pre-refund status.
async function loadOrderHistory() {
  const orders = await j("GET", "/api/orders");
  const body = $("order-history-body");
  body.innerHTML = "";
  for (const o of orders.slice().sort((a, b) => a.order_id - b.order_id)) {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>#${o.order_id}</td>
      <td>${o.customer_name}</td>
      <td>${o.product_name}</td>
      <td>${o.quantity}</td>
      <td>${money(o.total_pence)}</td>
      <td class="order-status order-status-${o.status}">${o.status}</td>`;
    body.appendChild(tr);
  }
}

// ---------- chat ----------

function addChatBubble(text, who, denied) {
  const log = $("chat-log");
  const bubble = document.createElement("div");
  bubble.className = `chat-bubble ${who}${denied ? " denied" : ""}`;
  bubble.textContent = text;
  log.appendChild(bubble);
  log.scrollTop = log.scrollHeight;
  return bubble;
}

// Quick-reply chips, shown above the input. Clicking one sends it through
// the exact same path as typing it -- no separate code path to keep honest.
const SUGGESTIONS = ["Check my order status", "Request a refund"];
function renderSuggestions() {
  const wrap = $("chat-suggestions");
  wrap.innerHTML = "";
  for (const text of SUGGESTIONS) {
    const chip = document.createElement("button");
    chip.type = "button";
    chip.className = "chip";
    chip.textContent = text;
    chip.addEventListener("click", () => {
      $("chat-input").value = text;
      $("chat-form").requestSubmit();
    });
    wrap.appendChild(chip);
  }
}

// ---------- floating widget open/close ----------

let _chatOpened = false;
function openChatWidget() {
  $("chat-launcher").classList.add("hidden");
  $("chat-widget").classList.remove("hidden");
  if (!_chatOpened) {
    _chatOpened = true;
    $("chat-open-time").textContent = fmtTime(Date.now() / 1000);
    addChatBubble("Hi! I'm the Mahi Stores assistant -- ask about an order, or request a refund.", "agent");
  }
  $("chat-input").focus();
}
function closeChatWidget() {
  $("chat-widget").classList.add("hidden");
  $("chat-launcher").classList.remove("hidden");
}
$("chat-launcher").addEventListener("click", openChatWidget);
$("chat-close-btn").addEventListener("click", closeChatWidget);
// No separate minimized state -- collapse just goes back to the launcher,
// same as close.
$("chat-collapse-btn").addEventListener("click", closeChatWidget);
// Decorative only -- there is no audio anywhere in this demo to mute.
$("chat-mute-btn").addEventListener("click", () => {
  const btn = $("chat-mute-btn");
  btn.textContent = btn.textContent.trim() === "🔊" ? "🔇" : "🔊";
});

// A loading-state label guessed from the customer's own message -- not
// fabricated telemetry, just what's about to be asked for. The real
// events (and which backend actually handled it) only arrive with the
// response; this bubble is removed the moment they do.
function _guessCallingLabel(message) {
  if (/refund/i.test(message)) return "Calling issue_refund…";
  if (/order|status|track|where is|find/i.test(message)) return "Calling lookup_order…";
  return "Calling support agent…";
}

$("chat-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const input = $("chat-input");
  const sendBtn = $("chat-form").querySelector("button[type=submit]");
  const message = input.value.trim();
  if (!message) return;
  addChatBubble(message, "user");
  input.value = "";

  const callingBubble = addChatBubble(_guessCallingLabel(message), "calling");
  const placeholder = input.placeholder;
  input.disabled = true;
  sendBtn.disabled = true;
  input.placeholder = "Waiting…";
  try {
    const resp = await j("POST", "/api/support/chat", {
      customer_id: state.customerId,
      agent: state.agent,
      message,
      thread_id: state.threadId,
    });
    callingBubble.remove();
    handleAgentResponse(resp);
  } catch (err) {
    callingBubble.remove();
    addChatBubble(`(error contacting agent: ${err})`, "agent", true);
  } finally {
    input.disabled = false;
    sendBtn.disabled = false;
    input.placeholder = placeholder;
    input.focus();
  }
});

function handleAgentResponse(resp) {
  const denied = (resp.events || []).some((e) => e.type === "denied");
  addChatBubble(resp.reply, "agent", denied);
  applyEvents(resp.events || []);
  if (resp.requires_approval) {
    state.pendingApproval = { approval_id: resp.approval_id, thread_id: state.threadId };
    showApprovalCard(resp.approval_text || "This action needs human approval.");
  }
}

// The storefront caches a human identity once (scripts/presenter-login.sh
// -> POST /api/admin/human-token), and this card just reflects that
// cache's status -- it never collects or sends a name itself any more.
// Polled on an interval while the card is visible so "expires in" counts
// down and the Approve button disables itself the moment the cache goes
// stale, instead of only discovering that on click. Not cryptographic --
// see index.html's comment on the approval card for the honest version of
// what this step does and doesn't guarantee.
let _humanTokenInterval = null;

async function refreshHumanToken() {
  const identityEl = $("approval-identity");
  const btn = $("approve-btn");
  try {
    const status = await j("GET", "/api/admin/human-token");
    if (status.present) {
      const mins = Math.floor(status.expires_in / 60);
      const secs = status.expires_in % 60;
      identityEl.textContent = `Approve as ${status.display_name} — expires in ${mins}:${String(secs).padStart(2, "0")}`;
      identityEl.className = "approval-identity ok";
      btn.disabled = false;
    } else {
      identityEl.textContent = "no human credential cached -- run scripts/presenter-login.sh";
      identityEl.className = "approval-identity alert";
      btn.disabled = true;
    }
  } catch (err) {
    identityEl.textContent = `(could not check human credential: ${err})`;
    identityEl.className = "approval-identity alert";
    btn.disabled = true;
  }
}

function showApprovalCard(text) {
  const card = $("approval-card");
  card.classList.remove("hidden");
  card.querySelector(".approval-text").textContent = text;
  refreshHumanToken();
  if (_humanTokenInterval) clearInterval(_humanTokenInterval);
  _humanTokenInterval = setInterval(refreshHumanToken, 5000);
}
function hideApprovalCard() {
  $("approval-card").classList.add("hidden");
  if (_humanTokenInterval) {
    clearInterval(_humanTokenInterval);
    _humanTokenInterval = null;
  }
}

$("approve-btn").addEventListener("click", async () => {
  if (!state.pendingApproval) return;
  try {
    const resp = await j("POST", "/api/support/resume", {
      agent: state.agent,
      thread_id: state.pendingApproval.thread_id,
    });
    hideApprovalCard();
    state.pendingApproval = null;
    handleAgentResponse(resp);
  } catch (err) {
    addChatBubble(`(error resuming: ${err})`, "agent", true);
  }
});

// beat 4's two live demonstrations (widen a Postgres role in Git and
// watch OPA still deny; kubectl apply a non-compliant pod and watch
// Kyverno reject it) are both presenter-terminal/kubectl actions, not UI
// buttons here -- unlike the old Vault talk's ceiling-probe button, there
// is no safe "probe with what you already have" equivalent: OPA's
// decision depends only on SPIFFE identity and request shape, never on
// live Postgres privilege, so a button here would have nothing real to
// click.

function resetFlowState() {
  state.identity = null;
  state.activeAgent = null;
  state.correlation = null;
  state.openStage = null;
  state.anyActivity = false;
  for (const c of CARDS) state.cardEvents[c.id] = [];
  $("stage-detail").classList.add("hidden");
}

$("reset-btn").addEventListener("click", async () => {
  await j("POST", "/api/admin/reset");
  resetFlowState();
  $("chat-log").innerHTML = "";
  $("event-stream").innerHTML = "";
  renderStageGraph();
  renderSuggestions();
  loadOrderHistory(); // reset reverts refunds -- the status column needs refreshing too
});

function _setCustomerId(id) {
  state.customerId = id;
  $("customer-picker").value = id;
  $("chat-customer-picker").value = id;
}
$("customer-picker").addEventListener("change", (e) => {
  _setCustomerId(parseInt(e.target.value, 10));
});
$("chat-customer-picker").addEventListener("change", (e) => {
  _setCustomerId(parseInt(e.target.value, 10));
});

// Two pickers, same options -- the Agentic Workflow tab's and the one inside
// the chat widget, kept in sync the same way the customer pickers are.
function _setAgent(mode) {
  state.agent = mode;
  $("agent-picker").value = mode;
  $("chat-agent-picker").value = mode;
  resetFlowState();
  renderStageGraph();
  drawConnectors(); // which cards are visible changed (legacy vs. the two real agents)
}
$("agent-picker").addEventListener("change", (e) => _setAgent(e.target.value));
$("chat-agent-picker").addEventListener("change", (e) => _setAgent(e.target.value));

// ---------- tabs ----------
// "Shop" is the consumer-facing view; "Agentic Workflow" holds the demo-only
// controls (customer/agent pickers) plus the flow panel -- a real shopper
// never sees those, so they don't live in the default view.

function switchTab(name) {
  for (const btn of document.querySelectorAll(".tab-btn")) {
    btn.classList.toggle("active", btn.dataset.tab === name);
  }
  $("tab-shop").classList.toggle("hidden", name !== "shop");
  $("tab-flow").classList.toggle("hidden", name !== "flow");
}
$("tab-btn-shop").addEventListener("click", () => switchTab("shop"));
$("tab-btn-flow").addEventListener("click", () => switchTab("flow"));

// ---------- Agentic Workflow: stage graph + order history ----------

// Shared per-event bookkeeping used by both a live turn (applyEvents) and
// the one-time backfill from /api/state's log (pollState) -- one place
// that knows how to route an event to its card and update derived state,
// so the two can't drift.
function _identityCardIdFor(spiffeId) {
  const key = _agentKeyFromSpiffeId(spiffeId);
  if (key === "refund") return "refund-agent";
  if (key === "order") return "order-agent";
  return "legacy-agent"; // no spiffe_id -- the static-password agent
}

// "denied" is now a THREE-way-routed type (unlike the old single-stage
// Vault/Postgres split): resource "identity" means Envoy Gateway's own
// JWT check refused the request (never reached OPA); resource "policy"
// means OPA's extAuth refused it (never reached mahi-tools); anything else
// (products/orders/refunds/customers/deployments/scale) means mahi-tools'
// own Postgres-GRANT or K8s-RBAC backstop refused it. Routed here, like
// "identity" already was, rather than via the flat CARD_BY_TYPE map, which
// has no way to key on a second field.
function _cardForDenied(resource) {
  if (resource === "identity") return "envoy-gateway";
  if (resource === "policy") return "opa-policy";
  return "database";
}

function _absorbEvent(e) {
  let cardId;
  if (e.type === "identity") cardId = _identityCardIdFor(e.spiffe_id);
  else if (e.type === "denied") cardId = _cardForDenied(e.resource);
  else cardId = CARD_BY_TYPE[e.type];
  if (cardId) state.cardEvents[cardId].push(e);

  if (e.type === "identity") {
    state.identity = e;
    state.activeAgent = _agentKeyFromSpiffeId(e.spiffe_id);
  }
  // The audit-ready proof point: who approved this, and what. Deliberately
  // NOT cleared by anything later -- the action is done, the record of who
  // authorised it persists regardless. See the Approval card's detail.
  if (e.type === "approval_granted") {
    state.correlation = {
      approved_by: e.approved_by,
      spiffe_id: state.identity && state.identity.spiffe_id,
      action: e.message,
      ts: e.ts || Date.now() / 1000,
    };
  }
}

function applyEvents(events) {
  for (const e of events) {
    logEvent(e);
    _absorbEvent(e);
  }
  if (events.length) state.anyActivity = true;
  renderStageGraph();
  playTurnAnimation(events); // fire-and-forget visual pulse, over already-settled text
  if (events.some((e) => e.type === "refund_issued")) loadOrderHistory(); // status just changed
}

// Actor tag for the terminal-style event stream -- derived from the
// event's own type, same real data the stage cards use, just labeled the
// way a log line would be.
function _actorTag(e) {
  if (e.type === "identity") return "agent";
  if (e.type === "denied" && (e.resource === "identity" || e.resource === "policy")) return "gateway";
  if (["approval_requested", "approval_granted", "approval_required"].includes(e.type)) return "gateway";
  if (["refund_issued", "scale_applied", "denied", "scope_violation"].includes(e.type)) return "postgres";
  return "agent";
}

function logEvent(e) {
  const log = $("event-stream");
  const line = document.createElement("div");
  line.className = `stream-line ${dotClassFor(e)}`;
  const time = document.createElement("span");
  time.className = "stream-time";
  time.textContent = `[${fmtTime(e.ts || Date.now() / 1000)}]`;
  const actor = document.createElement("span");
  actor.className = `stream-actor stream-actor-${_actorTag(e)}`;
  actor.textContent = `[${_actorTag(e)}]`;
  const text = document.createElement("span");
  text.className = "stream-text";
  text.textContent = e.message || e.type;
  line.append(time, actor, text);
  log.appendChild(line); // terminal-style: newest at the bottom, auto-scrolled
  log.scrollTop = log.scrollHeight;
  while (log.children.length > 60) log.removeChild(log.firstChild);
}

function dotClassFor(e) {
  if (e.type === "denied" || e.type === "error") return "critical";
  if (e.type === "approval_requested" || e.type === "approval_required") return "warning";
  if (e.type === "refund_issued" || e.type === "scale_applied" || e.type === "approval_granted") return "good";
  return "neutral";
}

function remainingLabel(expiresAt) {
  if (!expiresAt) return "";
  const remaining = Math.max(0, expiresAt - Date.now() / 1000);
  const m = Math.floor(remaining / 60);
  const s = Math.floor(remaining % 60);
  return `expires in ${m}:${String(s).padStart(2, "0")}`;
}

function buildStageGraphDOM() {
  const graph = $("stage-graph");
  graph.innerHTML = "";
  for (const stage of STAGES) {
    const col = document.createElement("div");
    col.className = "stage-col";
    col.id = `stagecol-${stage.id}`;
    const head = document.createElement("div");
    head.className = "stage-col-head";
    head.innerHTML = `<span class="stage-col-num">${stage.num}</span><span class="stage-col-label">${stage.label}</span>`;
    col.appendChild(head);
    const cardsWrap = document.createElement("div");
    cardsWrap.className = "stage-col-cards";
    for (const card of stage.cards) {
      const el = document.createElement("div");
      el.className = "flow-card";
      el.id = `card-${card.id}`;
      el.innerHTML = `
        <div class="flow-card-icon">${card.icon}</div>
        <div class="flow-card-body">
          <div class="flow-card-label">${card.label}</div>
          <div class="flow-card-sub" id="card-sub-${card.id}">${card.sub || "—"}</div>
          <div class="flow-card-tag hidden" id="card-tag-${card.id}"></div>
        </div>`;
      el.addEventListener("click", () => openStageDetail(card.id));
      cardsWrap.appendChild(el);
    }
    col.appendChild(cardsWrap);
    graph.appendChild(col);
  }

  // Connector lines -- every card in stage N to every card in stage N+1,
  // not one arrow per column. Identity has two cards (order-agent,
  // refund-agent); both get their own line converging into Gateway, so
  // the diagram shows both real registered agents actually connecting to
  // it, not just a generic column-to-column marker. Positions are
  // computed after layout in drawConnectors() -- built empty here.
  const svgNS = "http://www.w3.org/2000/svg";
  const connectorSvg = document.createElementNS(svgNS, "svg");
  connectorSvg.setAttribute("class", "connector-layer");
  connectorSvg.setAttribute("id", "connector-layer");
  const defs = document.createElementNS(svgNS, "defs");
  const marker = document.createElementNS(svgNS, "marker");
  marker.setAttribute("id", "connector-arrowhead");
  marker.setAttribute("viewBox", "0 0 8 8");
  marker.setAttribute("refX", "7");
  marker.setAttribute("refY", "4");
  marker.setAttribute("markerWidth", "7");
  marker.setAttribute("markerHeight", "7");
  marker.setAttribute("orient", "auto-start-reverse");
  const arrowShape = document.createElementNS(svgNS, "path");
  arrowShape.setAttribute("d", "M 0 0 L 8 4 L 0 8 z");
  arrowShape.setAttribute("class", "connector-arrowhead-fill");
  marker.appendChild(arrowShape);
  defs.appendChild(marker);
  connectorSvg.appendChild(defs);
  graph.appendChild(connectorSvg);

  // Bypass arc overlay -- shown only when a turn's real events reach
  // Credential without ever touching Approval (see updateBypassArc).
  const svg = document.createElementNS(svgNS, "svg");
  svg.setAttribute("class", "bypass-arc-layer hidden");
  svg.setAttribute("id", "bypass-arc-layer");
  const arcPath = document.createElementNS(svgNS, "path");
  arcPath.setAttribute("id", "bypass-arc-path");
  svg.appendChild(arcPath);
  graph.appendChild(svg);
  const label = document.createElement("div");
  label.className = "bypass-arc-label hidden";
  label.id = "bypass-arc-label";
  label.textContent = "bypass — under £100 threshold";
  graph.appendChild(label);

  const pulse = document.createElement("div");
  pulse.className = "graph-pulse hidden";
  pulse.id = "graph-pulse";
  graph.appendChild(pulse);

  drawConnectors();
}

// Coordinates relative to `container` via getBoundingClientRect, not
// offsetLeft/offsetTop -- cards are nested inside .stage-col, which is
// itself a positioning context (needed for the bypass arc/stage number),
// so offsetLeft on a card would be relative to the wrong ancestor.
function _rectRelativeTo(el, container) {
  const r = el.getBoundingClientRect();
  const c = container.getBoundingClientRect();
  return { left: r.left - c.left, top: r.top - c.top, width: r.width, height: r.height };
}

// Real connector lines, card to card -- every visible card in stage N to
// every visible card in stage N+1 (Identity's two agent cards both draw
// a line into Gateway; every other adjacent pair is a single straight
// line). Recomputed whenever which cards are visible can change (mode
// switch) or the layout reflows (window resize).
function drawConnectors() {
  const svg = $("connector-layer");
  const graph = $("stage-graph");
  if (!svg || !graph) return;
  while (svg.lastChild && svg.lastChild.tagName !== "defs") svg.removeChild(svg.lastChild);

  for (let i = 0; i < STAGES.length - 1; i++) {
    const fromEls = STAGES[i].cards
      .filter((c) => !c.modes || c.modes.includes(state.agent))
      .map((c) => $(`card-${c.id}`))
      .filter(Boolean);
    const toEls = STAGES[i + 1].cards
      .filter((c) => !c.modes || c.modes.includes(state.agent))
      .map((c) => $(`card-${c.id}`))
      .filter(Boolean);
    for (const fromEl of fromEls) {
      const from = _rectRelativeTo(fromEl, graph);
      for (const toEl of toEls) {
        const to = _rectRelativeTo(toEl, graph);
        const x1 = from.left + from.width;
        const y1 = from.top + from.height / 2;
        const x2 = to.left - 6; // short gap so the arrowhead doesn't touch the card border
        const y2 = to.top + to.height / 2;
        const midX = (x1 + x2) / 2;
        const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
        path.setAttribute("class", "connector-line");
        path.setAttribute("marker-end", "url(#connector-arrowhead)");
        path.setAttribute("d", `M ${x1} ${y1} C ${midX} ${y1}, ${midX} ${y2}, ${x2} ${y2}`);
        svg.appendChild(path);
      }
    }
  }
}
window.addEventListener("resize", () => drawConnectors());

function openStageDetail(id) {
  state.openStage = id;
  $("stage-detail").classList.remove("hidden");
  renderStageGraph();
}
$("stage-detail-close").addEventListener("click", () => {
  state.openStage = null;
  $("stage-detail").classList.add("hidden");
  renderStageGraph();
});

function renderStageGraph() {
  const isInsecure = state.agent === "insecure";

  for (const stage of STAGES) {
    for (const card of stage.cards) {
      const el = $(`card-${card.id}`);
      if (!el) continue;

      if (card.modes && !card.modes.includes(state.agent)) {
        el.classList.add("hidden");
        continue;
      }

      const events = state.cardEvents[card.id] || [];
      let subtitle = card.sub || "—";
      let tone = "";
      let tag = null;

      if (stage.id === "identity") {
        if (card.agentKey === "insecure") {
          subtitle = state.anyActivity ? "no identity -- just a password" : card.sub;
          tone = state.anyActivity ? "absent" : "";
        } else {
          // Kept live by pollState's /api/state polling, independent of
          // whether this agent handled the last turn -- both real,
          // registered agents show real data, not just the active one.
          const live = state.agentStatus && state.agentStatus[card.agentKey];
          const active = state.activeAgent === card.agentKey;
          if (live && live.identity && live.identity.spiffe_id) {
            tone = active ? "lit" : "registered";
            subtitle = active && events.length ? events[events.length - 1].message : `${card.sub} -- registered`;
          }
        }
      } else if (events.length) {
        subtitle = events[events.length - 1].message || "";
        tone = "lit";
      }

      // Current state, not "did this ever happen this session" -- an
      // approval that was later granted shouldn't stay stuck amber, and a
      // fresh credential after a revoke shouldn't stay stuck grey.
      const lastType = events.length ? events[events.length - 1].type : null;
      if (lastType === "approval_requested" || lastType === "approval_required") tone = "warning";
      if (lastType === "denied" || lastType === "scope_violation" || lastType === "error") tone = "critical";

      el.className = "flow-card" + (tone ? ` ${tone}` : "") + (state.openStage === card.id ? " open" : "");
      $(`card-sub-${card.id}`).textContent = subtitle;
      const tagEl = $(`card-tag-${card.id}`);
      if (tagEl) {
        tagEl.textContent = tag || "";
        tagEl.classList.toggle("hidden", !tag);
      }
    }
  }
  if (state.openStage) renderStageDetail(state.openStage);
}

// Which identity card the pulse should visit -- whichever agent actually
// handled the last turn, or the legacy agent in insecure mode. Falls
// back to order-agent (the default-routed, least-privilege agent) before
// any turn has happened yet.
function _identityCardId() {
  if (state.agent === "insecure") return "legacy-agent";
  return state.activeAgent === "refund" ? "refund-agent" : "order-agent";
}

// Builds the sequence of cards a pulse travels through for one turn's
// real events -- each stage lights independently off its OWN event
// type(s), so Gateway and Policy can never be conflated into one hop. An
// empty/small-talk turn just travels to the identity card and stops. A
// request the gateway's own JWT check refused never reaches anything
// past Gateway; one the gateway accepted but OPA refused never reaches
// Execute.
function hopPath(events) {
  const path = [_identityCardId()];
  const deniedResources = events.filter((e) => e.type === "denied").map((e) => e.resource);
  if (events.length === 0) return path; // small talk -- nothing travelled anywhere
  if (deniedResources.includes("identity")) {
    path.push("envoy-gateway");
    return path; // refused at the gateway -- the journey stops here
  }
  path.push("envoy-gateway"); // reached the gateway, JWT accepted
  path.push("opa-policy"); // OPA evaluated the request either way (allow or deny)
  if (events.some((e) => e.type === "approval_requested" || e.type === "approval_granted")) path.push("approval-card");
  if (events.some((e) => ["refund_issued", "scale_applied", "scope_violation"].includes(e.type))
      || deniedResources.some((r) => r !== "identity" && r !== "policy")) path.push("database");
  return path;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// Shows/hides the bypass arc -- real conditional logic (a refund under
// the threshold genuinely never asks for approval), not decoration: a
// turn that reached Credential without ever touching Approval earns the
// arc; one that went through Approval for real does not.
function updateBypassArc(show) {
  const layer = $("bypass-arc-layer");
  const label = $("bypass-arc-label");
  const arcPath = $("bypass-arc-path");
  if (!layer || !label || !arcPath) return;
  if (!show) {
    layer.classList.add("hidden");
    label.classList.add("hidden");
    return;
  }
  const from = $("stagecol-authenticate");
  const to = $("stagecol-credential");
  if (!from || !to) return;
  const x1 = from.offsetLeft + from.offsetWidth / 2;
  const x2 = to.offsetLeft + to.offsetWidth / 2;
  arcPath.setAttribute("d", `M ${x1} 38 Q ${(x1 + x2) / 2} 18 ${x2} 38`);
  label.style.left = `${(x1 + x2) / 2}px`;
  layer.classList.remove("hidden");
  label.classList.remove("hidden");
}

// A paced *replay* of the real event sequence, not a live network
// capture -- the backend events for a turn all arrive in one HTTP
// response, not a stream. Runs concurrently with the instant text/state
// update above; this is purely the "watch it travel" visual on top.
async function playTurnAnimation(events) {
  if (!events.length) return;
  const path = hopPath(events);
  const pulse = $("graph-pulse");
  if (!pulse) return;

  updateBypassArc(path.includes("database") && !path.includes("approval-card"));

  pulse.classList.remove("hidden");
  for (const cardId of path) {
    const cardEl = $(`card-${cardId}`);
    if (!cardEl) continue;
    pulse.style.left = `${cardEl.offsetLeft + cardEl.offsetWidth / 2}px`;
    pulse.style.top = `${cardEl.offsetTop + cardEl.offsetHeight / 2}px`;
    cardEl.classList.add("pulse-hit");
    await sleep(420);
    cardEl.classList.remove("pulse-hit");
  }
  await sleep(450);
  pulse.classList.add("hidden");
}

function renderStageDetail(cardId) {
  const card = CARDS.find((c) => c.id === cardId);
  if (!card) return;
  const stage = STAGES.find((s) => s.id === card.stageId);
  $("stage-detail-label").textContent = `${card.icon} ${card.label}`;
  $("stage-detail-what").textContent = stage.what;
  $("stage-detail-why").textContent = stage.why;

  const tagsEl = $("stage-detail-tags");
  tagsEl.innerHTML = "";
  for (const t of stage.tags) {
    const tag = document.createElement("span");
    tag.className = "tag";
    tag.textContent = t;
    tagsEl.appendChild(tag);
  }

  // live countdown -- identity (SVID, both real agents) only. There is no
  // credential lease anywhere in this build to show a countdown for --
  // the SVID's own expiry (checked by Envoy Gateway on every call) is the
  // only thing in this system with a TTL.
  const liveEl = $("stage-detail-live");
  liveEl.innerHTML = "";
  if (stage.id === "identity" && card.agentKey !== "insecure") {
    const live = state.agentStatus && state.agentStatus[card.agentKey];
    liveEl.classList.remove("hidden");
    liveEl.textContent =
      live && live.identity && live.identity.spiffe_id
        ? `${live.identity.spiffe_id} -- SVID ${remainingLabel(live.identity.svid_expires_at)}`
        : "registered -- no live status yet";
  } else if (card.id === "legacy-agent" && state.anyActivity) {
    liveEl.classList.remove("hidden");
    liveEl.textContent = "no SPIFFE identity -- this agent proves nothing about itself";
  } else {
    liveEl.classList.add("hidden");
  }

  // correlation -- the "audit-ready" proof point, Approval card only,
  // deliberately NOT cleared by anything later (see _absorbEvent)
  const corrBlock = $("stage-detail-correlation");
  if (card.id === "approval-card" && state.agent !== "insecure" && state.correlation) {
    corrBlock.classList.remove("hidden");
    $("corr-approver").textContent = state.correlation.approved_by || "—";
    $("corr-spiffe").textContent = state.correlation.spiffe_id || "—";
    $("corr-action").textContent = state.correlation.action || "—";
  } else {
    corrBlock.classList.add("hidden");
  }

  // this run
  const logEl = $("stage-detail-log");
  logEl.innerHTML = "";
  const events = state.cardEvents[cardId] || [];
  if (events.length === 0) {
    logEl.innerHTML = '<li class="tile-sub">nothing yet this run</li>';
  }
  for (const e of events) {
    const li = document.createElement("li");
    const time = document.createElement("time");
    time.textContent = fmtTime(e.ts || Date.now() / 1000);
    const text = document.createElement("span");
    text.textContent = e.message || e.type;
    li.append(time, text);
    logEl.appendChild(li);
  }
}

// Local ticking clock for live countdowns -- purely cosmetic, driven off
// the `expires_at`/`svid_expires_at` the agent already sent. Touches only
// the card subtitle (always) and the detail drawer (only when open),
// never re-derives status from a timer -- a card only lights up on a
// real event.
function tickMeter() {
  // Only the SVID's own expiry ticks now -- re-rendering the open drawer
  // recomputes remainingLabel() against the live clock. No lease, no
  // meter, no revoke-on-timer: identity itself is what expires.
  if (state.openStage) renderStageDetail(state.openStage);
}
setInterval(tickMeter, 1000);

// Poll server state so a page refresh mid-demo doesn't lose the log or
// the flow panel's progress -- and, now, so BOTH registered agents' real
// identity stay visible at all times, not just whichever one answered
// the last chat turn. api_state() (app/storefront/main.py) already
// proxies each backend's own /status endpoint for exactly this.
async function pollState() {
  try {
    const s = await j("GET", "/api/state");
    state.agentStatus = s.agents || {};
    // Only backfill the log/cardEvents once; live updates come from
    // direct chat/resume/revoke responses via applyEvents.
    if ($("event-stream").children.length === 0) {
      for (const e of s.log) {
        logEvent(e);
        _absorbEvent(e);
      }
      if (s.log.length) state.anyActivity = true;
    }
    renderStageGraph();
  } catch (_) {
    /* storefront/agents still coming up -- ignore and retry */
  }
}
setInterval(pollState, 4000);

(async function init() {
  buildStageGraphDOM();
  renderSuggestions();
  await loadCustomers();
  await loadProducts();
  await loadOrderHistory();
  await pollState();
  renderStageGraph();
})();
