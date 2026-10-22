package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/sycophant-md/sycophant/cmd/syco/internal/config"
)

func newSessionCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "session",
		Short: "Print the active profile and its resolved values",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfgDir := config.ConfigDir()
			profileFlag, _ := cmd.Flags().GetString("profile")
			p, err := config.LoadProfile(cfgDir, profileFlag, "")
			if err != nil {
				return err
			}
			fmt.Fprintf(os.Stdout, "Profile:   %s\n", p.Name)
			fmt.Fprintf(os.Stdout, "Server:    %s\n", p.Server)
			fmt.Fprintf(os.Stdout, "Workspace: %s\n", p.Workspace)
			return nil
		},
	}

	wsCmd := &cobra.Command{
		Use:   "workspace [name]",
		Short: "Set the workspace for the active profile",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			cfgDir := config.ConfigDir()
			profileFlag, _ := cmd.Flags().GetString("profile")
			return config.SetWorkspace(cfgDir, profileFlag, "", args[0])
		},
	}

	cmd.AddCommand(wsCmd)
	return cmd
}
