package cmd

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"

	"github.com/spf13/cobra"
	"golang.org/x/term"

	"github.com/sycophant-md/sycophant/cmd/syco/internal/config"
	"github.com/sycophant-md/sycophant/cmd/syco/internal/grpcclient"
	relaypb "github.com/sycophant-md/sycophant/cmd/syco/internal/proto/relay/v1"
)

func newLoginCmd() *cobra.Command {
	var email string

	cmd := &cobra.Command{
		Use:   "login",
		Short: "Authenticate with the cluster's IdP",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfgDir := config.ConfigDir()
			profileFlag, _ := cmd.Flags().GetString("profile")
			p, err := config.LoadProfile(cfgDir, profileFlag, "")
			if err != nil {
				return err
			}

			// Discover IdP config from the relay
			ctx := context.Background()
			conn, err := grpcclient.Dial(ctx, p.Server)
			if err != nil {
				return fmt.Errorf("connecting to relay: %w", err)
			}
			defer conn.Close()

			client := relaypb.NewRelayGatewayClient(conn)
			discResp, err := client.Discover(ctx, &relaypb.DiscoverRequest{})
			if err != nil {
				return fmt.Errorf("discover: %w", err)
			}

			// Prompt for email if not provided
			if email == "" {
				fmt.Fprint(os.Stderr, "Email: ")
				var e string
				fmt.Fscanln(os.Stdin, &e)
				email = strings.TrimSpace(e)
			}

			// Get password from env or TTY prompt
			password := os.Getenv("SYCO_PASSWORD")
			if password == "" {
				fmt.Fprint(os.Stderr, "Password: ")
				pwBytes, err := term.ReadPassword(int(os.Stdin.Fd()))
				if err != nil {
					return fmt.Errorf("reading password: %w", err)
				}
				fmt.Fprintln(os.Stderr)
				password = string(pwBytes)
			}

			// OIDC Resource Owner Password Credentials grant
			token, err := oidcPasswordGrant(
				discResp.Issuer,
				discResp.ClientId,
				discResp.CertificateAuthority,
				email,
				password,
			)
			if err != nil {
				return err
			}

			if err := config.SaveToken(cfgDir, p.Name, token); err != nil {
				return fmt.Errorf("saving token: %w", err)
			}

			fmt.Fprintln(os.Stderr, "Login successful.")
			return nil
		},
	}

	cmd.Flags().StringVar(&email, "email", "", "Email address for login")
	return cmd
}

func oidcPasswordGrant(issuer, clientID, caBundlePEM, username, password string) (string, error) {
	// Discover token endpoint from OIDC well-known
	wellKnown := strings.TrimSuffix(issuer, "/") + "/.well-known/openid-configuration"

	httpClient := buildHTTPClient(caBundlePEM)

	resp, err := httpClient.Get(wellKnown)
	if err != nil {
		return "", fmt.Errorf("fetching OIDC config from %s: %w", wellKnown, err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	// Simple JSON parse for token_endpoint
	tokenEndpoint := jsonStringField(body, "token_endpoint")
	if tokenEndpoint == "" {
		return "", fmt.Errorf("no token_endpoint in OIDC discovery response")
	}

	// Password grant
	data := url.Values{
		"grant_type": {"password"},
		"client_id":  {clientID},
		"username":   {username},
		"password":   {password},
		"scope":      {"openid email profile"},
	}
	resp, err = httpClient.PostForm(tokenEndpoint, data)
	if err != nil {
		return "", fmt.Errorf("token request: %w", err)
	}
	defer resp.Body.Close()

	tokenBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return "", fmt.Errorf("token request failed (%d): %s", resp.StatusCode, string(tokenBody))
	}

	idToken := jsonStringField(tokenBody, "id_token")
	if idToken == "" {
		return "", fmt.Errorf("no id_token in token response")
	}

	return idToken, nil
}

func buildHTTPClient(caBundlePEM string) *http.Client {
	if caBundlePEM == "" {
		return http.DefaultClient
	}
	pool, err := x509.SystemCertPool()
	if err != nil {
		pool = x509.NewCertPool()
	}
	pool.AppendCertsFromPEM([]byte(caBundlePEM))
	return &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				RootCAs: pool,
			},
		},
	}
}

// jsonStringField extracts a string field from a JSON object.
func jsonStringField(data []byte, key string) string {
	var m map[string]interface{}
	if err := json.Unmarshal(data, &m); err != nil {
		return ""
	}
	v, ok := m[key]
	if !ok {
		return ""
	}
	s, ok := v.(string)
	if !ok {
		return ""
	}
	return s
}
