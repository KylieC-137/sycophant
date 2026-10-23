use crate::cli::{TenantCmd, TenantSub};
use crate::commands::command::tenant_ns;
use crate::commands::{down, remove, secret, up};
use crate::scope::Scope;

pub(crate) fn run(cmd: TenantCmd) -> Result<(), String> {
    match cmd.sub {
        TenantSub::Up(c) => up::run(&c.values),
        TenantSub::Down(c) => down::run(
            &Scope::for_tenant(&tenant_ns(&c.name))?,
            c.keepalive.as_deref(),
        ),
        TenantSub::Remove(c) => remove::run(&Scope::for_tenant(&tenant_ns(&c.name))?),
        TenantSub::Secret(c) => secret::run(c),
    }
}
