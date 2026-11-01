PRODUCT_PACKAGES += nns-mount
PRODUCT_SYSTEM_EXT_PROPERTIES += ro.nns.mount.owner=init

PRODUCT_ARTIFACT_PATH_REQUIREMENT_ALLOWED_LIST += \
    system/bin/nns-mount \
    system/etc/init/init.nns-mount.rc
