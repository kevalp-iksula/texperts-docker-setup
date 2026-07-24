# UCT Insights — Adobe Commerce 2.4.7-p1 → 2.4.9

Distilled from the Upgrade Compatibility Tool run (`uct 3.0.27`, full codebase,
125 modules / 8,480 files). Raw reports: `docs/uct/uct-2.4.9.html` (open in a
browser) and `.json`. A 2.4.8 run was also done and is **identical in blockers**
(see §5), so going straight to 2.4.9 is the efficient path.

---

## The one-line takeaway
**Only ~20 issues actually block the upgrade; ~9,650 are "runs on 2.4.9, clean up
later." The blockers are 96% Vnecoms. Your own custom code is nearly clean.**

---

## 1. The numbers, read correctly

UCT totals: **20 CRITICAL, 5,302 ERROR, 4,369 WARNING.** But "ERROR" ≠ "blocker":

| Category | ~Count | Blocks the upgrade? |
|---|---|---|
| **Critical** — classes/constants removed in 2.4.9 | 20 | **YES — must fix** |
| Non-API usage (codes 1124/1429/1121/1328/1224/1420) | ~4,000 | No — runs, just not Adobe-guaranteed API |
| Deprecations (1439/1134/1440/1131/1334) | ~4,300 | No — runs on 2.4.9 |
| Coding-standard (5012 `@vars`, 5007 `glob()`, 5081/5082 templates, 5026 JS) | ~1,200 | No — pure lint/quality |

Only the **20 critical** stop the site running. Everything else is technical debt
on your own schedule — not upgrade work.

## 2. The critical blockers (18 real + 2 false positives)

**17 of 20 are Vnecoms** referencing classes removed in 2.4.9:

| Removed class/constant | Replacement direction | Vnecoms module |
|---|---|---|
| `Magento\Elasticsearch7\Model\Client\Elasticsearch` | OpenSearch client | module-vendors-product |
| `Magento\CatalogSearch\Model\Adapter\Mysql\Aggregation\DataProvider` | OpenSearch aggregation (MySQL search removed) | module-vendors-product |
| `Magento\LayeredNavigation\Block\Navigation\{Category,Search}` | new layered-nav blocks | vendors-layer-navigation / -search |
| `Magento\Framework\HTTP\ZendClient::POST` | `Laminas\Http` / Magento HTTP client | shipping-dhl |
| `Magento\CatalogGraphQl\...\ProductSearch\*` | new GraphQL resolver structure | module-vendors-product-graphql |
| `Magento\Eav\Model\Api\SearchCriteria\CollectionProcessor` | `Magento\Framework\Api\SearchCriteria\CollectionProcessor` | module-vendors-api |
| `Magento\Catalog\Block\Adminhtml\Product\Helper\Form\BaseImage` | replacement admin form element | module-vendors-product |
| case typos: `Framework\app\ObjectManager`, `FrameWork\DataObject`, `Catalog\Model\Catalog\Product` | fix casing | report / vendors / vendors-api |

**1 is in custom code:** `Texperts/OutofofficeNotification/etc/di.xml` references the
removed `Magento\Ui\Component\DataProvider\DataProvider` — a one-line swap.

**2 are false positives:** UCT scanned `Mageplaza/Blog/.../ckeditor.js` (a JS
library) as PHP → ignore.

## 3. Where the work concentrates — 96% Vnecoms

Of 7,647 vendor issues, **7,332 (96%) are Vnecoms**: `module-vendors` (834),
`module-vendors-sales` (802), `quotation` (785), `vendors-cms` (577),
`vendors-product` (431)… So the vendor-side effort is **almost entirely Vnecoms**.

This makes Vnecoms the single decision that governs the upgrade:
- **If Vnecoms ships a 2.4.9-compatible build** → a `composer update` clears ~17
  criticals + 96% of vendor issues at once. Days-scale.
- **If not** → patch the ~10 removed-class references in Vnecoms yourself. Bounded,
  but hands-on.

## 4. Your custom code is in good shape

- **55 of ~101 custom modules are completely clean** (zero issues); only 46 touched.
- **Exactly ONE custom critical** (OutofofficeNotification di.xml).
- The 2,044 custom issues (Mageplaza/Blog 742, Magecomp/Gstcharge 224, Lof/Autosearch
  215 lead) are all non-API/deprecation — none block. The Phase-2 static-scan risks
  (Zend_Pdf, core preferences) are real but "runs, modernize later," not blockers.

## 5. 2.4.8 vs 2.4.9 — no reason to stage

Identical blocker set: both show **20 criticals, 0 unique to either version**. Every
removed-class blocker was already removed in 2.4.8. A 2.4.7→2.4.8→2.4.9 path is the
same fixes done twice → **go straight to 2.4.9**.

| Target | Critical | Errors | Warnings |
|---|---|---|---|
| 2.4.8 | 20 | 5,304 | 4,241 |
| 2.4.9 | 20 | 5,302 | 4,369 |

## 6. Phase 3 sequence (data-driven)

1. **Resolve Vnecoms** (the gate): update to a 2.4.9-compatible build, or patch the
   ~10 removed-class references.
2. **Fix the 1 custom critical** (OutofofficeNotification di.xml).
3. **`composer update` → 2.4.9** (metapackage via root-update-plugin + 3rd-party
   bumps), resolve conflicts.
4. **`di:compile` → `setup:upgrade`** on the 249 profile (PHP 8.5 / MariaDB 11.4 /
   OpenSearch 3); fix runtime breakages iteratively.
5. **Ship.** The ~9,650 non-blocking items become a separate cleanup backlog, not part
   of reaching 2.4.9.

**Bottom line:** the upgrade is gated by one vendor (Vnecoms), not by issue volume.
Your code is ready; the open question is Vnecoms' 2.4.9 support.

---

## 7. Composer update availability for 3rd-party modules (2.4.9)

Checked with the EE key against **magento/framework 103.0.9** (what 2.4.9 ships).

**`composer why-not magento/framework 103.0.9` → NO 3rd-party module blocks 2.4.9.**
The only constraint blockers are Magento's own modules (payment-services,
data-exporter — they bump with the metapackage) and standard library upgrades
(Laminas ^2.2x, Symfony ^7.4, Monolog ^3.6, wikimedia/less.php ^5.5), which
`composer update` handles automatically. **Vnecoms included — no composer-level
conflict.** Vnecoms' problems are code-level (the UCT criticals), not resolution.

### Non-Vnecoms 3rd-party — updates available
| Package | Installed | Latest | Note |
|---|---|---|---|
| ampersand/magento2-disable-stock-reservation | 1.3.2 | 1.3.4 | minor bump |
| razorpay/magento | 4.1.6 | 4.2.2 | minor bump; verify checkout on 2.4.9 |
| wagento/zendesk | 220.0.18 | 220.0.25 | minor bump |
| cweagans/composer-patches | 1.7.3 | 2.0.0 | major (patch plugin) — optional |
| mageplaza/module-smtp, -customer-approval, -required-login | current | current | already latest within constraint |
| dompdf/dompdf, pusher/pusher-php-server | current | current | libraries, version-agnostic |

### Vnecoms — newer point releases exist (may fix some UCT criticals)
Several Vnecoms modules that hold the critical removed-class references have newer
builds available — bumping them could clear criticals **without manual patching**:

| Vnecoms module | Installed | Latest | Holds a critical? |
|---|---|---|---|
| module-vendors-shipping-dhl | 2.4.2 | 2.4.5 | yes — `ZendClient::POST` |
| module-vendors-api | 2.4.9 | 2.4.12 | yes — `Eav CollectionProcessor`, `Catalog\Product` typo |
| module-vendors-search | 2.4.4 | 2.4.5 | yes — `LayeredNavigation\...\Search` |
| module-vendors-quotation | 2.4.11 | 2.4.12 | — |
| module-vendors-shipping-fedex | 2.4.0 | 2.4.4 | — |
| module-vendors-shipping-{ups,usps} | 2.4.0 | 2.4.2 | — |
| module-vendors-subaccount | 2.4.7 | 2.4.8 | — |
| module-vendors-product-inventory | 2.1.2 | 2.1.5 | — |
| module-sms, module-vendors-page-ee | 2.4.23 / 2.0.2 | 2.4.24 / 2.0.3 | — |

### Recommended next step (before manual patching)
1. Bump Vnecoms + the 3rd-party packages to their latest versions in `composer.json`.
2. Re-run UCT — measure how many of the 17 Vnecoms criticals the newer builds clear.
3. Whatever criticals remain → patch by hand (the ~removed-class list in §2).

This front-loads the cheapest wins (vendor already did the work in newer releases)
and shrinks the manual patching to only what's genuinely left.
