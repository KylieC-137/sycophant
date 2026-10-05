use crate::cli::{TenantCmd, TenantSub};
use crate::commands::command::tenant_ns;
use crate::commands::{audit, down, remove, secret, up};
use crate::scope::Scope;

/// Dispatch a `syco tenant` subcommand. `down` and `remove` take the tenant
/// name. The others take `--ns`, a single global flag on `tenant` (declared
/// once, may appear anywhere on the line) the dispatcher resolves into the
/// per-tenant scope.
pub(crate) fn run(cmd: TenantCmd) -> Result<(), String> {
    let TenantCmd { ns, sub } = cmd;
    let scope = || -> Result<Scope, String> { Scope::for_tenant(require_ns(&ns)?) };
    match sub {
        TenantSub::Up(c) => up::run(&c.values),
        TenantSub::Down(c) => down::run(
            &Scope::for_tenant(&tenant_ns(&c.name))?,
            c.keepalive.as_deref(),
        ),
        TenantSub::Remove(c) => remove::run(&Scope::for_tenant(&tenant_ns(&c.name))?),
        TenantSub::Secret(c) => secret::run(&scope()?, c),
        TenantSub::Audit(c) => audit::run(&scope()?, c),
    }
}

fn require_ns(ns: &Option<String>) -> Result<&str, String> {
    ns.as_deref()
        .ok_or_else(|| "--ns <name> is required for this command".to_string())
}
