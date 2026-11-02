Product catalog logos, sourced from the official [cncf/artwork](https://github.com/cncf/artwork)
repo (the `icon/color` SVG variant for each project, plus Phippy from `other/phippy-and-friends/`).
All artwork in that repo is made available under the Linux Foundation's
[trademark usage guidelines](https://www.linuxfoundation.org/trademark-usage/), which permit this
kind of use -- accurately referencing a project in a talk/demo about that project, with no
implication that the project or the Linux Foundation endorses or sponsors this demo. **Mahi Stores
is a fictional demo storefront, not affiliated with or endorsed by CNCF, the Linux Foundation, or
any project below.**

The catalog items themselves (names, descriptions, approximate prices) are drawn from the real
[CNCF store](https://store.cncf.io/collections/all) as of 2026-11-02 -- but the product *photos*
on that store are its own copyrighted product photography, not freely licensed, so they are
deliberately **not** copied here. Each card instead shows the relevant project's logo rather than
a photo of the physical item.

| File | Project | Source |
|---|---|---|
| kubernetes.svg    | Kubernetes      | `projects/kubernetes/icon/color/kubernetes-icon-color.svg` |
| cncf.svg           | CNCF (general)  | `other/cncf/icon/color/cncf-icon-color.svg` |
| envoy.svg          | Envoy           | `projects/envoy/icon/color/envoy-icon-color.svg` |
| opa.svg            | Open Policy Agent | `projects/open-policy-agent/icon/color/opa-icon-color.svg` |
| spiffe.svg         | SPIFFE          | `projects/spiffe/icon/color/spiffe-icon-color.svg` |
| kyverno.svg        | Kyverno         | `projects/kyverno/icon/color/kyverno-icon-color.svg` |
| helm.svg           | Helm            | `projects/helm/icon/color/helm-icon-color.svg` |
| cloudnativepg.svg  | CloudNativePG   | `projects/cloudnativepg/icon/color/cloudnativepg-icon-color.svg` |
| argo.svg           | Argo            | `projects/argo/icon/color/argo-icon-color.svg` |
| phippy.svg         | Phippy & Friends | `other/phippy-and-friends/phippy_full.svg` |

Where a real CNCF store item is generically "CNCF"-branded rather than a specific sub-project's
own merch (a plain trucker cap, a fleece vest), its card is assigned one of the projects this
demo's own security stack actually runs (Envoy, OPA, SPIFFE, Kyverno, CloudNativePG, Argo) --
see `app/storefront/static/app.js`'s `PRODUCT_IMAGES` comment. That's a deliberate easter egg
(the swag you can "buy" features the same projects securing the checkout behind it), not a claim
about what the real store item ships with.

Full file history: all raw asset URLs are `https://raw.githubusercontent.com/cncf/artwork/master/<path above>`.
