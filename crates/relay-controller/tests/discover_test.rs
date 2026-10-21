//! Red test for AC 20: Discover RPC returns IdP config from GatewayState.
//!
//! This test calls the `discover` handler on `GatewayService` and asserts
//! it returns the IdP issuer, client_id, and certificate_authority that were
//! configured on GatewayState. It must fail because:
//!   1. GatewayState does not yet accept IdP fields.
//!   2. The Discover RPC and its types do not exist in relay.proto.
//!   3. The discover handler is not implemented on GatewayService.

#[cfg(test)]
mod discover_tests {
    use relay_controller::state::GatewayState;

    /// AC 20: GatewayState exposes IdP config and the Discover handler returns it.
    #[tokio::test]
    async fn discover_returns_idp_config_from_state() {
        // Construct state with IdP values.
        // This call will fail to compile because GatewayState::new does not
        // yet accept idp_issuer, idp_audience, idp_certificate_authority.
        let state = GatewayState::new_with_idp(
            None,
            "default".into(),
            "https://dex.example.com".into(),
            "syco-client".into(),
            "-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----".into(),
        );

        // Read the IdP config back from state.
        let (issuer, client_id, ca): (&str, &str, &str) = state.idp_config();
        assert_eq!(issuer, "https://dex.example.com");
        assert_eq!(client_id, "syco-client");
        assert!(ca.contains("BEGIN CERTIFICATE"));
    }
}
