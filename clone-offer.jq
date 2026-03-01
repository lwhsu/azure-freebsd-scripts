# clone-offer.jq -- Transform a resource-tree JSON into a /configure request body
#
# Parameters (via --arg / --argjson):
#   src_dot   Source version with dot, e.g., "14.3"
#   tgt_dot   Target version with dot, e.g., "14.4"
#   src_und   Source version with underscore, e.g., "14_3"
#   tgt_und   Target version with underscore, e.g., "14_4"
#   tgt_extid Target offer externalId, e.g., "freebsd-14_4"
#   ordinal   Ordinal text, e.g., "fifth release"
#   branch    Branch number, e.g., "14"
#   sig_versions  JSON object mapping "ARCH-FSTYPE-GEN" to SIG version string
#                 e.g., {"amd64-ufs-gen1":"2026.0301.00","arm64-zfs-gen2":"2026.0315.00"}
#                 Empty object {} means no vmImageVersions
#   sig_tag   SIG image definition tag, e.g., "RELEASE", "RC1", "BETA1"
#   sig_base  SIG resource path prefix, e.g.,
#             "/subscriptions/.../resourceGroups/.../providers/Microsoft.Compute/galleries/FreeBSD/images"
#   tenant_id Tenant ID for SIG sharedImage references
#   terms_of_use  Updated termsOfUse text (empty string = keep original)

# Helper: normalize $schema URLs to schema.mp.microsoft.com
def normalize_schema:
  if . then
    gsub("https://product-ingestion\\.azureedge\\.net/schema/"; "https://schema.mp.microsoft.com/schema/")
  else .
  end;

# Helper: extract schema type name from $schema URL
def schema_type:
  . as $s |
  ($s | ltrimstr("https://schema.mp.microsoft.com/schema/") | ltrimstr("https://product-ingestion.azureedge.net/schema/")) |
  split("/")[0];

# Helper: replace version strings in a text field
# Note: gsub treats its first arg as regex, so we must escape dots and underscores.
# We replace underscore form first (more specific), then dot form.
def replace_versions:
  gsub($src_und; $tgt_und) |
  gsub(($src_dot | gsub("\\."; "\\.")); $tgt_dot);

# Main transformation
.resources as $resources |

# Build plan_map: plan durable ID -> {extid, fstype, resourceName}
# Identify UFS and ZFS plans by their externalId suffix
[
  $resources[] |
  select(."$schema" | schema_type == "plan") |
  {
    id: .id,
    extid: .identity.externalId,
    fstype: (
      if (.identity.externalId | test("-ufs$")) then "ufs"
      elif (.identity.externalId | test("-zfs$")) then "zfs"
      else "default"
      end
    ),
    resourceName: (
      if (.identity.externalId | test("-ufs$")) then "planUfs"
      elif (.identity.externalId | test("-zfs$")) then "planZfs"
      else "planDefault"
      end
    )
  }
] as $plan_map |

# Filter out customer-leads and submission resources (auto-created by API)
[
  $resources[] |
  select(
    (."$schema" | schema_type) != "customer-leads" and
    (."$schema" | schema_type) != "submission" and
    (."$schema" | schema_type) != "resource-tree"
  )
] |

# Transform each resource
[
  .[] |
  # Normalize $schema URL
  ."$schema" |= normalize_schema |
  # Remove durable IDs
  del(.id) |

  # Get the resource type for this resource
  (."$schema" | schema_type) as $rtype |

  # Replace product durable ID references with resourceName
  (if .product and (.product | type) == "string" then
    .product = {"resourceName": "newProduct"}
  else . end) |

  # Replace plan durable ID references with resourceName
  (if .plan and (.plan | type) == "string" then
    # Find which plan this references
    (.plan) as $plan_ref |
    ([$plan_map[] | select(.id == $plan_ref)] | first // null) as $matched |
    if $matched then
      .plan = {"resourceName": $matched.resourceName}
    else .
    end
  else . end) |

  # Replace listing durable ID references with resourceName (in listing-asset)
  (if .listing and (.listing | type) == "string" then
    .listing = {"resourceName": "mainListing"}
  else . end) |

  # Resource-type-specific transformations
  if $rtype == "product" then
    .resourceName = "newProduct" |
    .identity.externalId = $tgt_extid |
    .alias = ("FreeBSD " + $tgt_dot + "-RELEASE")

  elif $rtype == "plan" then
    # Find this plan in plan_map by matching the original externalId pattern
    ([$plan_map[] | select(.extid == .extid)] | first // null) as $_unused |
    # Determine resourceName from the current externalId
    (if (.identity.externalId | test("-ufs$")) then "planUfs"
     elif (.identity.externalId | test("-zfs$")) then "planZfs"
     else "planDefault"
     end) as $rn |
    .resourceName = $rn |
    .identity.externalId = (.identity.externalId | replace_versions) |
    .alias = (.alias | replace_versions) |
    # Remove displayRank if present (let API assign)
    del(.displayRank)

  elif $rtype == "listing" then
    .resourceName = "mainListing" |
    .title = ("FreeBSD " + $tgt_dot + "-RELEASE") |
    .searchResultSummary = ("FreeBSD " + $tgt_dot + "-RELEASE") |
    .shortDescription = ("FreeBSD Operating System " + $tgt_dot + "-RELEASE. This is the " + $ordinal + " of the stable/" + $branch + " branch.") |
    .generalLinks = [
      .generalLinks[] |
      # Update URLs that contain version-specific paths
      .link |= replace_versions
    ]

  elif $rtype == "listing-asset" then
    # listing-asset: keep URLs as-is (logos are version-independent)
    .

  elif $rtype == "plan-listing" then
    # Determine fstype from the plan reference we already resolved
    (if .plan.resourceName == "planUfs" then " The root filesystem is using UFS."
     elif .plan.resourceName == "planZfs" then " The root filesystem is using ZFS."
     else ""
     end) as $fs_suffix |
    (if .plan.resourceName == "planUfs" then " (UFS)"
     elif .plan.resourceName == "planZfs" then " (ZFS)"
     else ""
     end) as $fs_label |
    .name = ("FreeBSD " + $tgt_dot + "-RELEASE" + $fs_label) |
    .description = ("FreeBSD Operating System " + $tgt_dot + "-RELEASE. This is the " + $ordinal + " of the stable/" + $branch + " branch." + $fs_suffix) |
    .summary = ("FreeBSD Operating System " + $tgt_dot + "-RELEASE" + $fs_label)

  elif $rtype == "price-and-availability-offer" then
    .

  elif $rtype == "price-and-availability-plan" then
    .

  elif $rtype == "virtual-machine-plan-technical-configuration" then
    # Update skuIds
    .skus = [.skus[] | .skuId |= replace_versions] |
    # Rebuild vmImageVersions from sig_versions
    if ($sig_versions | length) == 0 then
      .vmImageVersions = []
    else
      # Build vmImages array from sig_versions
      (
        [.skus[] |
          # Map imageType to arch-fstype-gen key
          (if .imageType == "x64Gen1" then
            # Determine fstype from skuId
            (if (.skuId | test("-ufs")) then "amd64-ufs-gen1"
             elif (.skuId | test("-zfs")) then "amd64-zfs-gen1"
             else "amd64-ufs-gen1"
             end)
          elif .imageType == "x64Gen2" then
            (if (.skuId | test("-ufs")) then "amd64-ufs-gen2"
             elif (.skuId | test("-zfs")) then "amd64-zfs-gen2"
             else "amd64-ufs-gen2"
             end)
          elif .imageType == "arm64Gen2" then
            (if (.skuId | test("-ufs")) then "arm64-ufs-gen2"
             elif (.skuId | test("-zfs")) then "arm64-zfs-gen2"
             else "arm64-zfs-gen2"
             end)
          else "unknown"
          end) as $key |
          if $sig_versions[$key] then
            {
              imageType: .imageType,
              source: {
                sourceType: "sharedImageGallery",
                sharedImage: {
                  tenantId: $tenant_id,
                  resourceId: ($sig_base + "/FreeBSD-" + $tgt_dot + "-" + $sig_tag + "-" +
                    ($key | split("-") | .[0]) + "-" +
                    ($key | split("-") | .[1]) + "-" +
                    ($key | split("-") | .[2]) +
                    "/versions/" + $sig_versions[$key])
                }
              }
            }
          else empty
          end
        ]
      ) as $vm_images |
      if ($vm_images | length) > 0 then
        .vmImageVersions = [{
          versionNumber: ($tgt_dot + ".0"),
          vmImages: $vm_images,
          lifecycleState: "generallyAvailable"
        }]
      else
        .vmImageVersions = []
      end
    end

  elif $rtype == "property" then
    if ($terms_of_use | length) > 0 then .termsOfUse = $terms_of_use else . end

  elif $rtype == "reseller" then
    .

  else .
  end
]
