package main

import (
	"context"
	"log"
	"os"

	"github.com/yanpla/incus-nix/internal/reconcile"
)

func main() {
	logger := log.New(os.Stdout, "incus-nix: ", 0)

	cfg := reconcile.Config{
		InstanceDataFile: os.Getenv("INSTANCE_DATA_FILE"),
		MarkerKey:        os.Getenv("MARKER_KEY"),
		Prune:            os.Getenv("PRUNE") == "true",
		Logger:           logger,
	}

	if err := reconcile.Run(context.Background(), cfg); err != nil {
		logger.Printf("ERROR: %v", err)
		os.Exit(1)
	}
}
