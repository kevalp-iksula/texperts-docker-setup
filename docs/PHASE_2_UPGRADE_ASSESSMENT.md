# Phase 2 — Upgrade Assessment: Adobe Commerce Cloud 2.4.7-p1 → 2.4.9

**Project:** `texperts` (Textile Trade Buddy) — Adobe Commerce **Cloud, Enterprise Edition**, `magento/magento-cloud-template`.
**Baseline running locally:** 2.4.7-p1 on the Cloud-matching stack (PHP 8.3 / MariaDB 10.6 / OpenSearch 2), June-prod DB imported.
**Assessment date:** 2026-07-17.

This document is the concrete, prioritized backlog for the upgrade. It is the output
of Phase 2; Phase 3 works this list.

---

## 0. TL;DR — the one thing that blocks everything

**The Composer keys in `auth.json` have Open Source (CE) access but NO Adobe Commerce
(Enterprise) entitlement.** Verified:

| Package | With current keys |
|---|---|
| `magento/product-community-edition` 2.4.9 | ✅ visible |
| `magento/product-enterprise-edition` (any) | ❌ "not found" |
| `magento/magento-cloud-metapackage` > 2.4.7 | ❌ "not found" |
| `magento/upgrade-compatibility-tool` (UCT) | ❌ "not found" (it is an AC tool) |

`texperts` is Adobe Commerce Cloud (EE), so **its core packages cannot be fetched**.
No `composer update` to 2.4.9 can run until this is resolved.

**Action (P0, owner: whoever administers the Adobe Commerce account):** issue Composer
access keys from the Adobe account that owns this Cloud project (the paid EE/Cloud
subscription), at commercemarketplace.adobe.com → Access Keys. Then replace the
`repo.magento.com` entry in `texperts/auth.json`. Re-verify with
`composer show -a magento/magento-cloud-metapackage` (should list 2.4.9).

Everything below is real work, but it is **gated** on this key.

---

## 1. Composer access & dependency matrix

Good news beyond the EE wall: **all four repos authenticate** (magento, vnecoms,
mageplaza, magecomp) and third-party vendors have current releases. `composer outdated`
shows only patch/minor bumps for the non-Magento packages — no abandoned dependencies.

| Package | Installed | Latest avail. | Note |
|---|---|---|---|
| magento/magento-cloud-metapackage | 2.4.7 | none matched | **EE entitlement blocker** |
| ampersand/disable-stock-reservation | 1.3.2 | 1.3.4 | routine bump |
| dompdf/dompdf | 3.1.0 | 3.1.5 | library, version-agnostic |
| mageplaza/module-smtp | 4.7.13 | 4.7.22 | routine bump |
| razorpay/magento | 4.1.6 | 4.2.2 | payment; verify 2.4.9 support |
| wagento/zendesk | 220.0.18 | 220.0.25 | hard-pinned in composer.json |
| magento/quality-patches | 1.1.48 | 1.1.82 | bump for 2.4.9 |
| vnecoms/* (marketplace suite, ~22 pkgs) | 2.4.x | 2.4.x+N | see risk below |

### Risk R1 — Vnecoms Marketplace 2.4.9 compatibility (HIGH, vendor-gated)
The Vnecoms EE marketplace (~22 packages, framework-level) is reachable and has newer
point releases, **but Vnecoms version numbers do not map to Magento versions and the
packages declare no `magento/framework` constraint** — so 2.4.9 support cannot be
inferred. This must be **confirmed directly with Vnecoms** (do they certify their
current build for AC 2.4.9?). If not, this is a hard blocker equal in weight to the EE
key. **Action (P0, owner: you → Vnecoms support).**

---

## 2. Patch triage (24 files in `m2-hotfixes/`, 4 wired into composer)

`cweagans/composer-patches` runs with `composer-exit-on-patch-failure: true`, so a patch
that fails to apply **aborts `composer install`**.

| Disposition | Count | Meaning |
|---|---|---|
| **DROP** | 9 | Superseded by 2.4.9 — every `VULN-*`, Adobe `AC-*`/`ACSD-*`, and PHP-8.x deprecation fix. 2.4.9 already includes them. |
| **REWORK** | 6 | Custom/Vnecoms changes to re-base on 2.4.9. **3 are identical duplicates** of one `bookmark`→`bookmarks` fix (`trail2.patch`, `trial.patch`, `fix-vnecoms-quotation-grid.patch`) — dedupe to one. |
| **VERIFY** | 9 | Re-confirm against 2.4.9 code (includes the 4 wired ones). |

### Risk R2 — the wired framework patch will likely break the build (HIGH)
`eav_missing_attribute_on_pdp.patch` (WIRED) patches core
`magento/framework .../UiComponentFactory.php` using fragile context (reordered `use`
imports, whitespace). 2.4.9 ships a new framework version; this almost certainly won't
apply → `composer install` aborts. **Action:** check whether 2.4.9 already guards the
empty-`$name` case (likely **DROP**); otherwise re-base. Also verify the other 3 wired
patches' package-key mappings — the agent found 3 of 4 keys don't match the real
`vnecoms/module-*` paths.

---

## 3. Custom code risk (app/code — ~101 modules: 94 Texperts + 7 others)

Encouraging: **no `Zend\`/`laminas` direct namespaces, no `create_function`, no `${}`
string interpolation, no dynamic-property syntax** — the nastier PHP 8.2/8.4 syntax
breakers are absent. The real risks are library removal, core overrides, and pins.

### Risk R3 — Zend Framework 1 (`Zend_*`) usage (HIGH)
43 files, ~235 refs. ZF1 (`magento/zendframework1`) is retired. Worst offenders:
- **`Zend_Pdf` PDF generation** — `Texperts/Sales/.../Pdf/PurchaseOrder.php`,
  `Texperts/Sales/Helper/PdfGenerator.php`, `Magecomp/Gstcharge/.../Pdf/{Invoice,Creditmemo}.php`.
  Rewrite to a supported PDF path (e.g. the bundled `dompdf`, already required).
- `Zend_Db_Expr` / `Zend_Db_Select` (×124) → `Magento\Framework\DB\Sql\Expression` /
  `Magento\Framework\DB\Select`.
- `Zend_Log*` (×10) → `Psr\Log\LoggerInterface`.

### Risk R4 — composer version pins that block 2.4.9 (HIGH, mechanical)
Module `composer.json` files pinned to 2.4.7-era framework:
- `magento/framework 100.0.*` — `Texperts/BuyerActivity` (hardest pin).
- `magento/framework 103.0.*` — `Texperts/Reward`, `Texperts/CustomCheckout`.
- `magento/module-config 101.2.*` — `Webkul/WhatsAppSharing`.
- Stale PHP ceilings excluding 8.4 (`~8.1||~8.2`, and even `~5.5|~5.6|~7.0`) in several
  Texperts modules + `Magecomp/Gstcharge`. All must widen to allow 8.3/8.4.

### Risk R5 — core `<preference>` overrides (MEDIUM-HIGH, per-module verify)
112 preferences overriding `Magento\*` core across ~40 modules. Most fragile:
- **`Magecomp/Gstcharge`** — 12 Sales/PDF preferences + `Zend_Pdf` + PHP ceiling. Single
  most fragile module (two breakage vectors).
- **`Texperts/Reward`** — 7 `Magento\Reward\*` preferences + framework pin + `Zend_Log`.
- **`Texperts/BuyerGroupPricing`** — 13 preferences on Catalog pricing / UI modifiers.
- `Texperts/DealoftheDay` (9), `Texperts/RemoveToplinks`/`Dashboard`/`AccountManager`
  (admin menu/topmenu overrides).
Each needs its overridden core class's 2.4.9 constructor/method signatures re-checked.

### Risk R6 — legacy setup scripts (MEDIUM)
Old-style scripts with no declarative `db_schema.xml`: `InstallData` in
`Texperts/{Warehouse,AccountManager,ProductAttachment}`, and `UpgradeSchema` in
`Lof/All`. Convert to data patches / declarative schema.

### Risk R7 — `ObjectManager::getInstance()` (LOW-MEDIUM, breadth)
162 direct calls. Not a hard blocker, but fragile against 2.4.9 constructor changes and
flagged by coding standards. Address opportunistically in the modules already being
touched.

### Risk R8 — `serialize()/unserialize()` (LOW, audit)
34 non-JSON sites. PHP 8.4 tightens `unserialize()`. Audit for PHP-serialized objects
persisted to DB/config; migrate to `SerializerInterface` (JSON).

---

## 4. Prioritized backlog

**P0 — unblock (do first, gates all code work)**
1. Obtain Adobe Commerce EE Composer keys → update `texperts/auth.json` (§0).
2. Confirm Vnecoms 2.4.9 certification with the vendor (§R1).

**P1 — make `composer update` to 2.4.9 resolve & install**
3. Raise root constraint `magento/magento-cloud-metapackage` `>=2.4.5 <2.4.8` → 2.4.9
   (via `magento/composer-root-update-plugin`, bump it to 2.0.6 first).
4. Widen/clear the blocking module composer pins & PHP ceilings (§R4).
5. Prune the 9 DROP patches; dedupe the 3 duplicate Vnecoms patches; resolve the wired
   framework patch (§R2). Bump `magento/quality-patches` to a 2.4.9 line.
6. Bump third-party modules to their 2.4.9-compatible releases (§1).

**P2 — make it run (after install succeeds, on the 2.4.9 profile)**
7. Rewrite `Zend_Pdf` PDF generation and remaining `Zend_*` usage (§R3).
8. Re-validate the fragile core preferences, starting Magecomp/Gstcharge, Texperts/Reward,
   BuyerGroupPricing (§R5).
9. Convert legacy setup scripts (§R6). `setup:upgrade` + `setup:di:compile` on PHP 8.5;
   fix DI-compile failures iteratively.
10. Migrate DB engine 10.6 → 11.4 (`make profile-249`), reindex on OpenSearch 3.

**P3 — validate & ship**
11. Storefront + admin smoke tests; exercise custom checkout, credit terms, DealOfTheDay,
    Reward, and the DP-733 voice-search feature.
12. Clean the polluted working tree; commit `composer.json`/`lock` + code on an upgrade
    branch; push → Cloud integration/staging → production.

---

## 5. Open questions / external dependencies
- **Adobe account owner:** who can issue EE Composer keys for this Cloud project?
- **Vnecoms:** is the current marketplace suite certified for AC 2.4.9? If not, timeline?
- **Third-party payment (Razorpay 4.2.x) / Zendesk / Magecomp GST:** confirm 2.4.9 support.

## 6. What can proceed WITHOUT the EE key (in parallel, on the 2.4.7 baseline)
The code-hygiene items are version-independent and de-risk the upgrade now:
- Rewrite `Zend_Pdf`/`Zend_*` (R3) — works on 2.4.7 too.
- Widen composer pins & PHP ceilings (R4).
- Dedupe/prune patches (R2, the DROP/dup set).
- Convert legacy setup scripts (R6).
Doing these on the running baseline shrinks the P2 list before the key even arrives.

---

## Appendix — Upgrade Compatibility Tool (UCT) results (2026-07-21)

Ran once the EE key was working (UCT is Adobe-Commerce-gated). `uct 3.0.27`,
2.4.7-p1 → 2.4.9, full codebase (125 modules, 8480 files). Reports saved:
`docs/uct/uct-2.4.9.html` (open in a browser) and `docs/uct/uct-2.4.9.json`.

**Totals:** 20 CRITICAL, 5302 ERROR, 4369 WARNING. 119/125 modules flagged.
Location: 2044 issues in custom `app/code`, 7647 in `vendor`.

**Read the severities correctly:**
- **ERROR (5302)** is mostly **non-API usage** (1124/1429/1121) and template style
  (5012/5007/5081/5082) — code that still *runs* on 2.4.9 but isn't on Adobe's stable
  API. Migrate over time; NOT upgrade blockers.
- **WARNING (4369)** = deprecations (Quote::save, Registry, etc.) — run fine on 2.4.9.
- **CRITICAL (20)** = classes/constants that **do not exist on 2.4.9** — the real blockers.

**The 20 critical are overwhelmingly in Vnecoms** (confirms Vnecoms = critical path):
- `Magento\Elasticsearch7\Model\Client\Elasticsearch` (ES removed → OpenSearch) — vnecoms/module-vendors-product
- `Magento\CatalogSearch\Model\Adapter\Mysql\Aggregation\DataProvider` (MySQL search removed) — vnecoms/module-vendors-product
- `Magento\LayeredNavigation\Block\Navigation\{Category,Search}` (removed) — vnecoms layer-navigation/search
- `Magento\CatalogGraphQl\...\ProductSearch\*` (removed) — vnecoms product-graphql
- `Magento\Eav\Model\Api\SearchCriteria\CollectionProcessor` (removed) — vnecoms vendors-api
- `Magento\Catalog\Block\Adminhtml\Product\Helper\Form\BaseImage` (removed) — vnecoms vendors-product
- `Magento\Framework\HTTP\ZendClient::POST` (Zend removed) — vnecoms shipping-dhl
- case-typo classes `Magento\Framework\app\ObjectManager`, `Magento\FrameWork\DataObject`,
  `Magento\Catalog\Model\Catalog\Product` (trivial casing fixes) — vnecoms report/vendors/api

**In custom `app/code`:** only ONE real critical —
`Texperts/OutofofficeNotification/etc/di.xml` references
`Magento\Ui\Component\DataProvider\DataProvider` (removed). The 2 "PHP syntax error"
criticals are **false positives** (UCT scanning `Mageplaza/Blog/.../ckeditor.js`, a JS
library, as PHP).

**Top custom modules by issue volume** (mostly ERROR/WARNING, not critical):
Mageplaza/Blog 742, Magecomp/Gstcharge 224, Lof/Autosearch 215, Texperts/ProductAttributes
91, Texperts/Quotation 73, Lof/All 64, Texperts/CustomerAddresses 60, Infibeam/Ccavenue 55,
Texperts/Sales 51.

**UCT vs the Phase-2 static scan:** UCT confirms every Phase-2 conclusion (Vnecoms top
risk, Zend removal, Magecomp/Gstcharge fragility) and adds the precise removed-class list.
Net: **the upgrade is feasible; the hard blocker is Vnecoms referencing 2.4.9-removed
classes** — either Vnecoms ships 2.4.9 builds, or these specific references get patched.
