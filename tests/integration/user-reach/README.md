# user-reach/

A person reaches a workspace only through the user command: the installer
renders one reach RoleBinding per listed workspace and the relay-identity
ConfigMap that binds the person's channel handles. These tests drive real user
commands through admission and the installer and assert what the bound subject
can and cannot reach.

| Test                                                            | What it proves                                                                 |
|-----------------------------------------------------------------|--------------------------------------------------------------------------------|
| user-command-renders-reach-rolebindings-and-identity-configmap/ | An operator-written user command binds exactly the listed workspaces and handles; re-granting without one cuts it; a writer without namespace write RBAC is denied |
| user-command-vap-rejects-unsafe-subject/                        | The user-command VAP admits a safe subject and refuses one carrying a quote, backslash, LF, CR, U+2028, or U+2029 |

Belongs here: subject reach, handle binding, and the user command's admission
contract. Doesn't belong here: tampering with the identity ConfigMap after it
is rendered (see `tenant-resource-protection/`).
