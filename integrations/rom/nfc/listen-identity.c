/* Present a chosen ISO14443-A listen identity on the ST54J NFC controller.
 *
 * Experimental. Not part of the ROM image. Requires root and a stopped NFC
 * HAL, because the vendor HAL owns /dev/st21nfc while NFC is enabled.
 *
 * The controller can store a UID, ATQA byte and SAK and can listen as a type A
 * card. It cannot answer MIFARE Classic Crypto1 authentication, so this is an
 * identity-level emulation, not a MIFARE block clone.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define ST21NFC_MAGIC 0xEA
#define ST21NFC_PULSE_RESET _IOR(ST21NFC_MAGIC, 0x02, unsigned int)
#define ST21NFC_SET_POLARITY_HIGH _IOR(ST21NFC_MAGIC, 0x05, unsigned int)
#define ST21NFC_CLK_ENABLE _IOR(ST21NFC_MAGIC, 0x11, unsigned int)
#define ST21NFC_CLK_DISABLE _IOR(ST21NFC_MAGIC, 0x12, unsigned int)

#define NFC_DEVICE "/dev/st21nfc"

#define NCI_STATUS_OK 0x00
#define NCI_STATUS_DISCOVERY_ALREADY_STARTED 0xA0

#define DEFAULT_ATQA 0x04
#define DEFAULT_PLATFORM 0x0C
#define DEFAULT_SAK 0x20

static int device_fd = -1;
static volatile sig_atomic_t stop_requested = 0;

static void handle_stop(int signal_number) {
  (void)signal_number;
  stop_requested = 1;
}

static void print_hex(const char *label, const uint8_t *data, size_t length) {
  printf("%s (%zu):", label, length);
  for (size_t index = 0; index < length; index++) {
    printf(" %02x", data[index]);
  }
  printf("\n");
  fflush(stdout);
}

static int read_packet(uint8_t *buffer, size_t capacity, int timeout_ms) {
  struct pollfd entry = {.fd = device_fd, .events = POLLIN};
  int ready = poll(&entry, 1, timeout_ms);
  if (ready == 0) {
    return 0;
  }
  if (ready < 0) {
    return errno == EINTR ? 0 : -1;
  }
  if (read(device_fd, buffer, 3) != 3) {
    return -1;
  }
  if (buffer[0] == 0x7E || buffer[1] == 0x7E) {
    return 0;
  }
  size_t remaining = buffer[2];
  if (3 + remaining > capacity) {
    fprintf(stderr, "frame too large: %zu bytes\n", remaining);
    return -1;
  }
  size_t received = 0;
  while (received < remaining) {
    ssize_t part = read(device_fd, buffer + 3 + received, remaining - received);
    if (part <= 0) {
      return -1;
    }
    received += (size_t)part;
  }
  return (int)(3 + received);
}

static int send_command(const uint8_t *packet, size_t length) {
  print_hex("TX", packet, length);
  ssize_t written = write(device_fd, packet, length);
  if (written != (ssize_t)length) {
    fprintf(stderr, "write failed: %s\n", strerror(errno));
    return -1;
  }
  return 0;
}

/* Wait for one response, print every frame seen, return its status. */
static int wait_response(uint8_t group, uint8_t oid, int timeout_ms) {
  uint8_t buffer[512];
  for (;;) {
    int received = read_packet(buffer, sizeof buffer, timeout_ms);
    if (received <= 0) {
      return -1;
    }
    print_hex("RX", buffer, (size_t)received);
    if ((buffer[0] >> 5) == 2 && (buffer[0] & 0x0F) == group &&
        buffer[1] == oid) {
      return received >= 4 ? buffer[3] : -1;
    }
  }
}

static void wait_notification(uint8_t group, uint8_t oid, int timeout_ms) {
  uint8_t buffer[512];
  for (;;) {
    int received = read_packet(buffer, sizeof buffer, timeout_ms);
    if (received <= 0) {
      return;
    }
    print_hex("RX", buffer, (size_t)received);
    if ((buffer[0] >> 5) == 3 && (buffer[0] & 0x0F) == group &&
        buffer[1] == oid) {
      return;
    }
  }
}

static int parse_hex(const char *text, uint8_t *output, size_t length) {
  if (strlen(text) != length * 2) {
    return -1;
  }
  for (size_t index = 0; index < length; index++) {
    unsigned int value = 0;
    if (sscanf(text + index * 2, "%2x", &value) != 1) {
      return -1;
    }
    output[index] = (uint8_t)value;
  }
  return 0;
}

static void print_usage(const char *program) {
  printf("usage: %s [options]\n", program);
  printf("\n");
  printf("  --uid HEX8        NFCID1, four bytes, for example 04112233\n");
  printf("  --sak HEX2        SEL info, default %02x (ISO-DEP), "
         "08 looks like MIFARE Classic\n", DEFAULT_SAK);
  printf("  --atqa HEX2       bit frame SDD byte, default %02x\n",
         DEFAULT_ATQA);
  printf("  --platform HEX2   platform config, default %02x\n",
         DEFAULT_PLATFORM);
  printf("  --seconds N       stop after N seconds, default 0, run until "
         "signal\n");
  printf("\n");
  printf("Stop NFC before running: svc nfc disable\n");
  printf("The tool resets the controller configuration when it exits.\n");
}

/* Bring the controller from power-on to a state that accepts RF commands.
 * The order matches the vendor HAL: reset, init, credits, mode set, reset,
 * init again. Discovery is rejected before the mode set completes. */
static int initialize_controller(void) {
  const uint8_t core_reset[] = {0x20, 0x00, 0x01, 0x01};
  const uint8_t core_init[] = {0x20, 0x01, 0x02, 0x00, 0x00};
  const uint8_t mode_set_on[] = {0x2F, 0x02, 0x02, 0x02, 0x01};

  if (ioctl(device_fd, ST21NFC_SET_POLARITY_HIGH) < 0 ||
      ioctl(device_fd, ST21NFC_PULSE_RESET) < 0) {
    fprintf(stderr, "reset ioctl failed: %s\n", strerror(errno));
    return -1;
  }
  usleep(60000);
  if (ioctl(device_fd, ST21NFC_CLK_ENABLE) < 0) {
    fprintf(stderr, "clock enable failed: %s\n", strerror(errno));
    return -1;
  }
  wait_notification(0, 0x00, 400);

  if (send_command(core_reset, sizeof core_reset) < 0) {
    return -1;
  }
  if (wait_response(0, 0x00, 500) != NCI_STATUS_OK) {
    fprintf(stderr, "CORE_RESET was rejected\n");
    return -1;
  }
  wait_notification(0, 0x00, 300);

  if (send_command(core_init, sizeof core_init) < 0) {
    return -1;
  }
  if (wait_response(0, 0x01, 700) != NCI_STATUS_OK) {
    fprintf(stderr, "CORE_INIT was rejected\n");
    return -1;
  }
  wait_notification(0, 0x06, 400);

  if (send_command(mode_set_on, sizeof mode_set_on) < 0) {
    return -1;
  }
  if (wait_response(0x0F, 0x02, 700) != NCI_STATUS_OK) {
    fprintf(stderr, "PROP_NFC_MODE_SET was rejected\n");
    return -1;
  }
  wait_notification(0, 0x00, 700);

  if (send_command(core_init, sizeof core_init) < 0) {
    return -1;
  }
  if (wait_response(0, 0x01, 700) != NCI_STATUS_OK) {
    fprintf(stderr, "second CORE_INIT was rejected\n");
    return -1;
  }
  wait_notification(0, 0x06, 400);
  return 0;
}

static int set_identity(uint8_t atqa, uint8_t platform, uint8_t sak,
                        const uint8_t uid[4]) {
  const uint8_t map[] = {0x21, 0x00, 0x07, 0x02, 0x04, 0x03,
                         0x02, 0x05, 0x03, 0x03};
  if (send_command(map, sizeof map) < 0) {
    return -1;
  }
  if (wait_response(1, 0x00, 500) != NCI_STATUS_OK) {
    fprintf(stderr, "RF_DISCOVER_MAP was rejected\n");
    return -1;
  }

  uint8_t config[24];
  size_t length = 0;
  config[length++] = 0x20;
  config[length++] = 0x02;
  size_t length_index = length++;
  config[length++] = 0x05;
  config[length++] = 0x30;
  config[length++] = 0x01;
  config[length++] = atqa;
  config[length++] = 0x31;
  config[length++] = 0x01;
  config[length++] = platform;
  config[length++] = 0x32;
  config[length++] = 0x01;
  config[length++] = sak;
  config[length++] = 0x33;
  config[length++] = 0x04;
  memcpy(config + length, uid, 4);
  length += 4;
  config[length++] = 0x00;
  config[length++] = 0x02;
  config[length++] = 0x00;
  config[length++] = 0x01;
  config[length_index] = (uint8_t)(length - 3);

  if (send_command(config, length) < 0) {
    return -1;
  }
  if (wait_response(0, 0x02, 600) != NCI_STATUS_OK) {
    fprintf(stderr, "CORE_SET_CONFIG was rejected\n");
    return -1;
  }

  const uint8_t get_config[] = {0x20, 0x03, 0x05, 0x04,
                                0x30, 0x31, 0x32, 0x33};
  if (send_command(get_config, sizeof get_config) < 0) {
    return -1;
  }
  int status = wait_response(0, 0x03, 600);
  if (status != NCI_STATUS_OK) {
    fprintf(stderr, "CORE_GET_CONFIG returned status %d\n", status);
    return -1;
  }
  return 0;
}

static int start_listening(void) {
  const uint8_t discover[] = {0x21, 0x03, 0x03, 0x01, 0x80, 0x01};
  if (send_command(discover, sizeof discover) < 0) {
    return -1;
  }
  int status = wait_response(1, 0x03, 500);
  if (status == NCI_STATUS_OK) {
    return 0;
  }
  if (status == NCI_STATUS_DISCOVERY_ALREADY_STARTED) {
    printf("discovery was already running\n");
    return 0;
  }
  fprintf(stderr, "RF_DISCOVER listen A returned status %d\n", status);
  return -1;
}

static void print_events(void) {
  uint8_t buffer[512];
  for (;;) {
    int received = read_packet(buffer, sizeof buffer, 0);
    if (received <= 0) {
      return;
    }
    int message_type = buffer[0] >> 5;
    int group = buffer[0] & 0x0F;
    if (message_type == 3) {
      if (group == 1 && buffer[1] == 0x04) {
        printf("reader field detected\n");
      } else if (group == 1 && buffer[1] == 0x05) {
        printf("remote endpoint activated\n");
      } else {
        print_hex("NTF", buffer, (size_t)received);
      }
    } else if (message_type == 0) {
      print_hex("DATA", buffer, (size_t)received);
    } else {
      print_hex("RX", buffer, (size_t)received);
    }
    fflush(stdout);
  }
}

static void listen_until_stopped(long seconds) {
  struct timespec start;
  clock_gettime(CLOCK_MONOTONIC, &start);
  printf("listening as type A card, UID set, stop with Ctrl-C\n");
  fflush(stdout);
  while (!stop_requested) {
    if (seconds > 0) {
      struct timespec now;
      clock_gettime(CLOCK_MONOTONIC, &now);
      if (now.tv_sec - start.tv_sec >= seconds) {
        break;
      }
    }
    struct pollfd entry = {.fd = device_fd, .events = POLLIN};
    int ready = poll(&entry, 1, 200);
    if (ready > 0) {
      print_events();
    } else if (ready < 0 && errno != EINTR) {
      fprintf(stderr, "poll failed: %s\n", strerror(errno));
      break;
    }
  }
}

static void reset_controller(void) {
  const uint8_t deactivate[] = {0x21, 0x06, 0x01, 0x00};
  const uint8_t core_reset[] = {0x20, 0x00, 0x01, 0x01};
  send_command(deactivate, sizeof deactivate);
  wait_response(1, 0x06, 300);
  send_command(core_reset, sizeof core_reset);
  wait_response(0, 0x00, 500);
  ioctl(device_fd, ST21NFC_CLK_DISABLE);
}

int main(int argc, char **argv) {
  uint8_t uid[4] = {0x04, 0x11, 0x22, 0x33};
  uint8_t atqa = DEFAULT_ATQA;
  uint8_t platform = DEFAULT_PLATFORM;
  uint8_t sak = DEFAULT_SAK;
  long seconds = 0;

  static const struct option options[] = {
      {"uid", required_argument, NULL, 'u'},
      {"sak", required_argument, NULL, 's'},
      {"atqa", required_argument, NULL, 'a'},
      {"platform", required_argument, NULL, 'p'},
      {"seconds", required_argument, NULL, 't'},
      {"help", no_argument, NULL, 'h'},
      {NULL, 0, NULL, 0},
  };

  int option = 0;
  while ((option = getopt_long(argc, argv, "u:s:a:p:t:h", options, NULL)) !=
         -1) {
    switch (option) {
      case 'u':
        if (parse_hex(optarg, uid, sizeof uid) < 0) {
          fprintf(stderr, "invalid UID: %s\n", optarg);
          return 1;
        }
        break;
      case 's':
        if (parse_hex(optarg, &sak, 1) < 0) {
          fprintf(stderr, "invalid SAK: %s\n", optarg);
          return 1;
        }
        break;
      case 'a':
        if (parse_hex(optarg, &atqa, 1) < 0) {
          fprintf(stderr, "invalid ATQA byte: %s\n", optarg);
          return 1;
        }
        break;
      case 'p':
        if (parse_hex(optarg, &platform, 1) < 0) {
          fprintf(stderr, "invalid platform config: %s\n", optarg);
          return 1;
        }
        break;
      case 't':
        seconds = strtol(optarg, NULL, 10);
        if (seconds < 0) {
          fprintf(stderr, "invalid duration: %s\n", optarg);
          return 1;
        }
        break;
      case 'h':
        print_usage(argv[0]);
        return 0;
      default:
        print_usage(argv[0]);
        return 1;
    }
  }

  struct sigaction action;
  memset(&action, 0, sizeof action);
  action.sa_handler = handle_stop;
  sigaction(SIGINT, &action, NULL);
  sigaction(SIGTERM, &action, NULL);

  device_fd = open(NFC_DEVICE, O_RDWR);
  if (device_fd < 0) {
    fprintf(stderr, "open %s failed: %s\n", NFC_DEVICE, strerror(errno));
    fprintf(stderr, "disable NFC first: svc nfc disable\n");
    return 1;
  }

  int result = 1;
  if (initialize_controller() < 0) {
    fprintf(stderr, "controller initialization failed\n");
    goto cleanup;
  }
  if (set_identity(atqa, platform, sak, uid) < 0) {
    fprintf(stderr, "identity configuration failed\n");
    goto cleanup;
  }
  if (start_listening() < 0) {
    fprintf(stderr, "listen mode was not accepted\n");
    goto cleanup;
  }

  printf("this emulation presents an identity only; it does not answer "
         "MIFARE Classic authentication\n");
  listen_until_stopped(seconds);
  result = 0;

cleanup:
  reset_controller();
  close(device_fd);
  device_fd = -1;
  return result;
}
