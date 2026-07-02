// Conformance: официальный sentry-go должен доставить ошибку в Swatter,
// зная только DSN (ADR-0001). Запуск: SWATTER_DSN=... go run .
package main

import (
	"fmt"
	"os"
	"time"

	"github.com/getsentry/sentry-go"
)

func main() {
	dsn := os.Getenv("SWATTER_DSN")
	if dsn == "" {
		fmt.Fprintln(os.Stderr, "SWATTER_DSN not set")
		os.Exit(2)
	}

	err := sentry.Init(sentry.ClientOptions{
		Dsn:         dsn,
		Release:     "conformance@0.0.1",
		Environment: "conformance",
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "sentry init:", err)
		os.Exit(1)
	}

	sentry.CaptureException(fmt.Errorf("conformance: hello from sentry-go"))

	if !sentry.Flush(5 * time.Second) {
		fmt.Fprintln(os.Stderr, "flush timeout")
		os.Exit(1)
	}
	fmt.Println("event sent")
}
