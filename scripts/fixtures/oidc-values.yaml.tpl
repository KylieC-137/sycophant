oidc:
  issuer: ${OIDC_FIXTURE_ISSUER}
  clientId: ${OIDC_FIXTURE_AUDIENCE}
  egress:
    inCluster:
      endpointSelector:
        matchLabels:
          app.kubernetes.io/name: oidc-fixture
      port: 8080
