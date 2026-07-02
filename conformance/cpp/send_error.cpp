// Conformance: официальный sentry-native (C++) должен доставить событие
// в Swatter, зная только DSN (ADR-0001). Собирается через CMakeLists.txt.
// Запуск: SWATTER_DSN=... ./send_error
#include <sentry.h>

#include <cstdio>
#include <cstdlib>

int main() {
  const char *dsn = std::getenv("SWATTER_DSN");
  if (!dsn) {
    std::fprintf(stderr, "SWATTER_DSN is not set\n");
    return 2;
  }

  sentry_options_t *options = sentry_options_new();
  sentry_options_set_dsn(options, dsn);
  sentry_options_set_release(options, "conformance@0.0.1");
  sentry_options_set_environment(options, "conformance");
  sentry_init(options);

  sentry_value_t event = sentry_value_new_message_event(
      SENTRY_LEVEL_ERROR, "logger", "conformance: hello from sentry-native");
  sentry_capture_event(event);

  // sentry_close дренит транспорт (flush) перед выходом
  sentry_close();
  std::printf("event sent\n");
  return 0;
}
