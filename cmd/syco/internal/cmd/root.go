// Package cmd implements the syco CLI commands.
package cmd

import (
	"github.com/spf13/cobra"
)

// Root returns the top-level cobra command for the syco CLI.
func Root() *cobra.Command {
	root := &cobra.Command{
		Use:          "syco",
		Short:        "Sycophant end-user CLI",
		SilenceUsage: true,
	}

	root.PersistentFlags().String("profile", "", "Profile to use (overrides SYCO_PROFILE and [default].profile)")

	root.AddCommand(
		newLoginCmd(),
		newLogoutCmd(),
		newWhoamiCmd(),
		newSessionCmd(),
		newProfileCmd(),
		newChatCmd(),
	)

	return root
}
