# NFC listen identity experiment

Experimental. Not part of the ROM image, not enabled by the ROM integration, and
not deployed. It answers one question: can the phone present a card identity that
software chooses?

## Result

The controller accepts a chosen ISO14443-A identity and listens as a type A card.
It cannot answer MIFARE Classic authentication. So a UID-level emulation is
possible, and a full MIFARE Classic block clone is not.

The old Lenovo P2a42 could clone and cast MIFARE Classic cards because its NXP
chip had a MIFARE Classic emulation mode in firmware. The ST54J in this phone has
no equivalent. No kernel change adds that mode.

## Hardware and software found on the phone

| Item | Value |
|---|---|
| Controller | ST54J |
| Driver | `st21nfc.ko`, character device `/dev/st21nfc`, misc 115 |
| Secure element link | `/dev/st54spi`, misc 497 |
| HAL | `android.hardware.nfc-service.st`, `nfc_nci.st21nfc.default.so` |
| Firmware | `/vendor/firmware/st54j_fw.bin`, `st54j_conf.bin` |
| NCI stack | `/apex/com.android.nfcservices/lib64/libnfc_nci_jni.so` |
| Kernel NFC core | `nfc.ko`, loaded but unused by the vendor driver |

## Why the kernel is not involved

The driver carries NCI frames and handles clock, reset, polarity and recovery.
It does no RF work. The chip firmware and the NCI commands decide what the antenna
emits.

The kernel therefore needs no patch. Userspace can already send any NCI frame to
`/dev/st21nfc`. The only access rule is SELinux and device ownership, and the
root domain already passes.

## Controller initialization

A reset and `CORE_INIT` are not enough. The controller rejects every RF command
until the vendor mode set completes. The order below was read from the running
HAL with verbose logging enabled for one session.

| Step | Frame | Meaning |
|---:|---|---|
| 1 | `20 00 01 01` | CORE_RESET, reset configuration |
| 2 | `20 01 02 00 00` | CORE_INIT, two payload bytes |
| 3 | `60 06` | credits notification, wait for it |
| 4 | `2f 02 02 02 01` | proprietary mode set on, status 0 |
| 5 | `60 00` trigger `a0` | controller resets itself |
| 6 | `20 01 02 00 00` | CORE_INIT again |

Step 4 must come after step 3. Before the mode set, `RF_DISCOVER` answers
`REJECTED` and `RF_DEACTIVATE` answers `FAILED`.

## Discovery encoding

`RF_DISCOVER_CMD` is `21 03 03 01 <type> <frequency>`, one configuration per
command, frequency `01`. A second discovery command while discovery runs answers
`0xA0`. Send `RF_DEACTIVATE` idle (`21 06 01 00`) between tests.

Accepted types:

| Type | Mode |
|---:|---|
| `0x00` | poll A |
| `0x01` | poll B |
| `0x02` | poll F |
| `0x03` | poll A active |
| `0x06` | poll ISO15693 |
| `0x80` | listen A |
| `0x81` | listen B |
| `0x82` | listen F |
| `0x83` | listen A active |

Rejected types:

| Type | Mode |
|---:|---|
| `0x86` | listen ISO15693 |
| `0x87` to `0xFF` | every vendor listen candidate |

There is no MIFARE listen type. The Android stack has no MIFARE card-emulation
path either; it carries ISO-DEP and FeliCa card emulation only.

## Identity parameters

Listen A identity comes from `CORE_SET_CONFIG` parameters `0x30` to `0x33`.

| Parameter | Meaning | Value used |
|---:|---|---|
| `0x30` | bit frame SDD, ATQA byte | `04` |
| `0x31` | platform config | `0c` |
| `0x32` | SEL info, the SAK | `20`, then `08` |
| `0x33` | NFCID1, the UID | `04 11 22 33` |

`CORE_GET_CONFIG` read back the exact values:

```
40 03 11 00 04  30 01 04  31 01 0c  32 01 08  33 04 04 11 22 33
```

The controller stored the chosen identity, and listen A was accepted with SAK
`0x20` (ISO-DEP) and with SAK `0x08` (MIFARE Classic 1K appearance).

## What this permits and what it does not

Permitted:

- A reader that compares only UID, ATQA and SAK sees the chosen identity.
- The identity survives a read-back and listen mode starts.

Not permitted:

- MIFARE Classic authentication. The controller has no Crypto1 engine in listen
  mode and no MIFARE listen type.
- Sector reads and writes. A reader that authenticates fails after selection.
- ISO15693 listen. The controller rejects that discovery type.

Full MIFARE Classic cloning needs hardware: a UID-writable magic card, a Proxmark,
a Flipper or a Chameleon.

## Tool

`listen-identity.c` performs the sequence and holds listen mode. It prints every
frame and the read-back identity.

Build a static phone binary:

```sh
nix shell nixpkgs#zig -c zig cc -target aarch64-linux-musl -static -O2 \
  -o nns-nfc-listen-identity integrations/rom/nfc/listen-identity.c
```

Run it:

```sh
adb push nns-nfc-listen-identity /data/local/tmp/
adb shell 'svc nfc disable; /data/local/tmp/nns-nfc-listen-identity \
  --uid 04112233 --sak 08 --seconds 60'
adb shell 'svc nfc enable'
```

Options:

| Option | Meaning | Default |
|---|---|---|
| `--uid HEX8` | NFCID1, four bytes | `04112233` |
| `--sak HEX2` | SEL info, the SAK | `20` |
| `--atqa HEX2` | bit frame SDD byte | `04` |
| `--platform HEX2` | platform config | `0c` |
| `--seconds N` | stop after N seconds | `0`, run until signal |

The tool resets the controller configuration when it exits, because a stale
listen identity would otherwise stay in the controller. Enable NFC again after
the run; the Android stack reinitializes the controller.

Stop the NFC HAL or disable NFC before the run. The vendor HAL owns
`/dev/st21nfc` while NFC is enabled.

## Method

The initialization order and the RF command behavior were captured from the live
HAL. For one session the HAL configuration file was bind-mounted read-only inside
the init mount namespace with `STNFC_HAL_LOGLEVEL=4`, and the HAL service was
restarted. The bind mount was removed and the service restarted again after the
capture. Log level returned to 1.

Discovery types were tested one at a time, each after an explicit deactivate.
Status values are the low byte of each response frame.

## Risk and cleanup

- Firmware was not written. `st54j_fw.bin` and `st54j_conf.bin` are unchanged.
- The HAL configuration file was not modified on disk. The bind mount was
  temporary and was removed.
- NFC was disabled during each probe and enabled afterwards. The HAL service runs
  and `nfc.initialized` is true.
- Probe binaries and temporary files were removed from `/data/local/tmp`.

## Open item

The controller accepted and stored the identity. On-air emission was not observed,
because no second reader was available. Tap a second reader or phone against the
device while the tool runs and compare the reported UID, ATQA and SAK.

## Evidence

Raw run logs and the HAL capture are outside the repository on the operator
machine, under `~/.local/state/nns-rom/nfc-listen/`.
