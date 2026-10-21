package main

import (
	"fmt"
	"os"

	"github.com/sycophant-md/sycophant/cmd/syco/internal/cmd"
)

func main() {
	if err := cmd.Root().Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
