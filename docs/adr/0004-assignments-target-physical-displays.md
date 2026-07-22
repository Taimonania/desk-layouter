# Assignments target physical Displays, never the Main role

Status: Accepted (physical-Display persistence and migration implemented in #21;
multi-Display editing, Apply, and Arrange implemented in #22)

Desk Layouter persists an Assignment destination as a specific physical Display plus a positional Desktop number. The macOS Main Display role is only a runtime adapter concern: whichever physical Display is Main may be represented by the private `"Main"` monitor alias, but that alias is never persisted as identity and changing Main does not change the user's Assignment. A proposed semantic **Follow Main Display** destination was rejected because macOS ultimately stores a concrete Desktop UUID, so following the role would require topology-driven re-Apply behavior and would make a saved board depend on a temporary system role.

The physical Display is identified by its ColorSync UUID with presentation and hardware recovery metadata; transient Core Graphics display IDs, private monitor keys, geometry, and Display numbers are not identity. Apply resolves the saved Display and Desktop number to the current concrete Desktop UUID. If that effective UUID changes while the semantic Assignment does not, Apply becomes pending without marking the Preset edited. When a Display cannot be resolved, Desk Layouter preserves its Assignment and existing macOS binding; a uniquely matching recovery identity may be adopted only after user confirmation. This decision requires **Displays have separate Spaces** for Apply and Arrange and extends the positional Desktop model established in [CONTEXT.md](../../CONTEXT.md).

The runtime topology is one ordered snapshot of logical Display sections. An
extended Display is one section; a mirror set is one section containing every
physical member and sharing the primary's Desktop set. Apply plans explicit
updates, explicit deletions, and preservations independently, then revalidates
physical identities, Main role, mirrors, separate-Spaces mode, geometry, and
ordered Desktop UUIDs immediately before mutation. A topology mismatch performs
no write and no Dock restart. Automatic Space rearrangement is a warning because
Desktop numbers remain positional, not an Apply/Arrange blocker.
