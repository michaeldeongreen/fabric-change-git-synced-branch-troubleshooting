# Fabric Git branch-switch / missing-shortcut lab

A disposable, two-Lakehouse lab for the customer's `main -> dev` workspace
branch change. No external storage, production data, Spark notebook, pipeline,
or paid capacity provisioning is needed.

**Important distinction:** selecting a Git conflict winner selects an item
definition. It does not create the data folder that a shortcut references.
An identical branch switch is not, by itself, a Git conflict.

## What is already set up

- This private repository belongs to `michaeldeongreen`.
- `main`, `dev`, and `feature/shortcut-lab` initially contain identical scaffolding.
- One isolated workspace on the existing Fabric trial capacity.
- Source Lakehouse `lh_git_source`, with three synthetic Files folders:
  `git-sync-lab/main`, `git-sync-lab/dev`, and `git-sync-lab/workspace`.
- Each folder contains `sample.csv`, identifying its target:

  ```csv
  id,branch
  1,main
  ```

- Consumer Lakehouse `lh_git_consumer`, with the internal OneLake shortcut
  `Files/branch_target`, initially pointing to the source's `main` folder.
- The current workspace is healthy. All three target folders are present.

Runtime IDs and diagnostic snapshots are kept locally under ignored
[.lab/](.lab/). Access tokens are obtained in memory and are never written to
files. The helper refuses to mutate a workspace whose saved name/description
does not match this lab.

### Authentication boundary

**The Fabric workspace is not yet connected to Git.** GitHub CLI authentication
does not automatically create a Fabric GitHub connection. No existing Fabric
GitHub connection was available, and the integrated browser required sign-in.
The CLI's OAuth token was not copied into Fabric or persisted as a credential.

The interactive connection below is the remaining prerequisite for the actual
UI branch-switch/conflict tests. The backend controls in the next section have
already been exercised independently of Git.

## What was actually observed

| Control | Observed result |
| --- | --- |
| Existing target; apply a `dev` Lakehouse definition | Succeeded; reading the shortcut returned `1,dev`. |
| Remove only the synthetic `dev` target; apply its definition with `updateDefinition` | **Succeeded.** This API path did not reproduce the customer's Git workload error. |
| Read that now-dangling Files shortcut | HTTP 404, `PathNotFound`. |
| Create/overwrite that shortcut using the shortcuts API while its target is missing | HTTP 400, `BadRequest` / `RequestBodyValidationFailed`, **`Target path doesn't exist`**. |
| Restore the target and retry the shortcut request | Succeeds; the target is readable again. |
| Final state | All targets restored; consumer points to `main`, and `1,main` is readable. |

This reproduces the **missing-target validation message**, not yet the exact
`InvalidShortcutPayloadBatchErrors` wrapper seen in the customer's Git UI.
The different behavior of `updateDefinition` and the shortcuts API is important:
do not treat a successful definition import as proof the shortcut works.

Raw error details and before/after snapshots remain under ignored
[.lab/evidence/](.lab/evidence/) and [.lab/snapshots/](.lab/snapshots/).

## Open the existing lab

Run these commands from this repository folder in PowerShell:

```powershell
$lab = Get-Content .\.lab\state.json -Raw | ConvertFrom-Json
Start-Process "https://app.fabric.microsoft.com/groups/$($lab.workspaceId)/list"
.\scripts\Invoke-FabricLab.ps1 -Action Snapshot
```

Sign in with the Fabric account used by the existing Azure CLI session.
If using another machine, `-Action Setup` creates a **new** disposable lab; it
does not reconstruct the old lab without its local state.

## 1. Connect `main`, then derive the baseline branches

1. In the lab workspace, open **Workspace settings -> Git integration**.
2. Select **GitHub**. Authorize/create a Fabric GitHub connection for
   `michaeldeongreen/fabric-change-git-synced-branch-troubleshooting`, following
   the current [Fabric connection instructions][get-started]. Keep any required
   token in Fabric's credential UI, not in this repository or the chat.
3. Select branch **`main`** and Git folder **`fabric`**.
4. The Git folder initially has no Fabric items. Select the direction that
   **commits the workspace's items to Git**, not one that replaces/deletes the
   workspace from the empty folder. Complete the first commit in Fabric.
5. Confirm both Lakehouses are present in Source control and that the consumer's
   Lakehouse settings track **Shortcuts / OneLake**. A serialized
   `shortcuts.metadata.json` must appear in its Git item folder.
6. Prepare the branches from that actual Fabric baseline:

   ```powershell
   .\scripts\Prepare-LabBranches.ps1 -Scenario Identical
   ```

The helper fast-forwards `dev` and `feature/shortcut-lab` to the new `main`
baseline. It never force-pushes or resets branches. It finds the consumer by
its service-generated `.platform` metadata, rather than assuming its directory
has a friendly name. Pushes use the active GitHub CLI account without changing
global Git credential settings.

**Do not copy raw pre-Git `getDefinition` exports into the sync folder.**
The API returned an all-zero logical ID before the first Git connection.
Let Fabric's first Git commit establish the item's identity; subsequent
scenarios preserve that identity.

## 2. Identical-branch control

In **Source control -> More options (...) -> Switch branch**, switch the same
clean workspace from `main` to `dev`. Read `sample.csv` through
`lh_git_consumer -> Files -> branch_target`; it should still contain `1,main`.
Switch back to `main`.

Native Switch branch refuses uncommitted workspace changes. It also warns that
items absent from the destination branch can be deleted. Do not bypass that
guard by discarding edits silently.

Expected: no conflict simply because a new branch was selected.

## 3. Different, but valid, branch definitions

Keep the Fabric workspace on clean `main`, then run:

```powershell
.\scripts\Prepare-LabBranches.ps1 -Scenario Divergent
```

This changes only the existing shortcut's **target path** on remote `dev` to
`Files/git-sync-lab/dev`. It preserves the shortcut name, item IDs, logical IDs,
and other Lakehouse settings.

Native-switch the Fabric workspace to `dev`; expect `1,dev`. Switch back to
`main`; expect `1,main`. Both source folders still exist, so this is the positive
control for a real branch difference without a missing dependency.

## 4. Missing target during `main -> dev`

Leave the Fabric workspace on clean `main`:

```powershell
.\scripts\Invoke-FabricLab.ps1 -Action BreakTarget -Target dev -AllowDestructiveLabChange
.\scripts\Invoke-FabricLab.ps1 -Action Snapshot
```

Only the lab source's `Files/git-sync-lab/dev` leaf folder is removed.
The current `main` shortcut remains readable. Now native-switch Fabric to
`dev` and capture the result:

- Does switching fail with the customer's workload error/message?
- Does it instead succeed, but leave a shortcut whose read returns 404?
- Did any items update before failure? Do not assume an atomic rollback.

Run `-Action Snapshot` after the attempt. It saves the snapshot **before**
trying the shortcut read, so evidence is retained even if that read fails.
Also copy the Fabric UI's complete technical details.

Repair by restoring the actual target, then retrying the same operation:

```powershell
.\scripts\Invoke-FabricLab.ps1 -Action RestoreTarget -Target dev
```

If the workspace is still on `main`, retry Switch branch to `dev`. If it is
already on `dev` with pending incoming changes, retry Update instead. Verify
the status and the actual CSV read, not just disappearance of the dialog.

### The independently verified shortcut API control

To isolate missing-target validation without needing Git:

```powershell
.\scripts\Invoke-FabricLab.ps1 -Action BreakTarget -Target dev -AllowDestructiveLabChange
.\scripts\Invoke-FabricLab.ps1 -Action SetShortcut -Target dev
# Expected: HTTP 400 / RequestBodyValidationFailed / Target path doesn't exist.
.\scripts\Invoke-FabricLab.ps1 -Action RestoreTarget -Target dev
.\scripts\Invoke-FabricLab.ps1 -Action SetShortcut -Target dev
.\scripts\Invoke-FabricLab.ps1 -Action Snapshot
```

Run the restoration even after a failed command. `-Action Apply` exercises the
public Lakehouse definition API instead; it is deliberately labeled as **not a
Git branch-switch test**.

## 5. Actual conflict, then conflict + missing target

Start on clean, synced `dev` with all targets present:

```powershell
# Workspace-side change to the same consumer Lakehouse:
.\scripts\Invoke-FabricLab.ps1 -Action SetShortcut -Target workspace
# Independent repository-side change to that Lakehouse's description:
.\scripts\Prepare-LabBranches.ps1 -Scenario Conflict
```

Refresh Fabric Source control. The **same Lakehouse** changed on both sides,
which is the documented condition for a Conflict. An unrelated notebook change
would not be an adequate control.

With every target valid, select **Update -> Resolve conflicts**:

- **Accept incoming changes** keeps the branch item, losing the workspace edit.
- **Keep current content** retains the workspace item and leaves it as
  uncommitted changes; commit it or use Fabric **Undo** to discard only the
  disposable lab edits before another test.

Run each direction in a separate clean test. `-Scenario Conflict` generates a
new Git-side description change each time so the test can be repeated.
For the repeatable baseline, prefer **Undo** after Keep current content.
If you instead commit the `workspace` target, use `SetShortcut -Target dev`
and commit that restoration before the next combined test.

For the combined failure, repeat the conflict setup, then remove the `dev`
target **before** resolving the conflict. The incoming version points to `dev`;
the workspace version points to the still-valid `workspace` target. Compare the
two resolutions instead of assuming both must fail.

If necessary to explain both choices failing, separately remove the synthetic
`workspace` target too; now both candidate versions have invalid targets.
Restore **both** targets before recovery. This is a deliberate lab extension,
not proof that the customer has two missing targets.

## 6. Customer-route variant and safe recovery

Ask the CSA to distinguish **native Switch branch** from changing Git settings
by **disconnecting and reconnecting**. The latter's initialization direction
can overwrite all connected workspace items or the branch's item definitions,
not merely the conflicted Lakehouse.

Only if native switching does not reproduce the behavior, repeat that exact
disconnect/reconnect route in this disposable workspace. Capture the selected
initialization direction. Do not recommend this as the first customer fix.

For customer troubleshooting:

1. Capture the exact operation, branch names/head commits, item logical/physical
   IDs, selected resolution direction, complete error, request/activity IDs,
   and failed Lakehouse definition.
2. Inspect each selected shortcut's target workspace, item, path, and access
   using the affected identity. Distinguish a missing path from denied access
   or incorrect environment mapping.
3. Restore the **correct real target and data**, or intentionally retarget/remove
   an obsolete shortcut after checking dependencies. Recreating an empty folder
   is only sufficient for this synthetic CSV lab, not a production-data fix.
4. Reapply the intended definition, confirm Git state, and actually read the
   shortcut. Selecting a conflict winner alone is not a dependency repair.
5. Compare `.platform` identities and branch diffs before renaming anything.
   GUID-named Git item folders are a [documented fallback][source-format] when
   the display-name-based directory is unavailable; they do not establish
   corruption. Do not regenerate logical IDs or rename folders casually.

Deleting a shortcut and deleting its source data are different operations.
This helper deliberately deletes only named synthetic source folders to inject
the failure; it offers no customer-workspace or broad cleanup command.

## Helper reference

| Action / scenario | Purpose |
| --- | --- |
| `Invoke-FabricLab -Action Setup` | Resume this saved lab or create a new isolated trial lab. |
| `-Action Snapshot` | Save target existence, shortcuts, definition, Git state, and try the CSV read. |
| `-Action SetShortcut -Target main/dev/workspace` | Upsert the workspace's shortcut using the shortcuts API. |
| `-Action BreakTarget -Target ... -AllowDestructiveLabChange` | Delete only one synthetic source leaf folder. |
| `-Action RestoreTarget -Target ...` | Recreate that synthetic folder and CSV. |
| `-Action Export` | Save the consumer's raw service definition locally for inspection. |
| `-Action Apply -Target ... -AllowDestructiveLabChange` | Change the target in the service definition and import it; not a Git test. |
| `Prepare-LabBranches -Scenario Identical/Divergent/Conflict` | Prepare and push the corresponding remote branch control after the first Fabric Git commit. |

Setup resumes partial provisioning from local state. Running it again resets
the lab's synthetic target CSVs and consumer shortcut to `main`; preserve
pending lab experiments before rerunning Setup.

## Validation

These tests create only an isolated local Git fixture or mocked HTTP responses;
they do not modify Fabric or GitHub:

```powershell
.\tests\Test-FabricRequests.ps1
.\tests\Test-PrepareLabBranches.ps1
```

They cover long-running-operation polling and failure reporting, CSV decoding,
explicit destructive-action guards, branch scenario creation, repeatable
same-item changes, preservation of logical/target IDs, and refusal to operate
on the wrong repository, a dirty worktree, an empty identity, or already-diverged
branches. Use a separate PowerShell invocation for each test if running a suite
from another script, so their local mocks remain isolated.

## References

- [Lakehouse metadata, shortcut tracking, and data not tracked by Git][lakehouse-git]
- [Switch branch behavior and uncommitted-change restriction][branches]
- [What constitutes a conflict and resolution directionality][conflicts]
- [Git source layout and logical-ID directory fallback][source-format]
- [Lakehouse definition schema][definition]
- [Shortcut create/update API][shortcuts]
- [OneLake addressing and storage-scoped authentication][onelake]
- [Fabric GitHub connection and credentials][git-connect]

[get-started]: https://learn.microsoft.com/en-us/fabric/cicd/git-integration/git-get-started
[lakehouse-git]: https://learn.microsoft.com/en-us/fabric/data-engineering/lakehouse-git-deployment-pipelines
[branches]: https://learn.microsoft.com/en-us/fabric/cicd/git-integration/branched-workspace#switch-branches
[conflicts]: https://learn.microsoft.com/en-us/fabric/cicd/git-integration/conflict-resolution
[source-format]: https://learn.microsoft.com/en-us/fabric/cicd/git-integration/source-code-format
[definition]: https://learn.microsoft.com/en-us/rest/api/fabric/articles/item-management/definitions/lakehouse-definition
[shortcuts]: https://learn.microsoft.com/en-us/rest/api/fabric/core/onelake-shortcuts/create-shortcut
[onelake]: https://learn.microsoft.com/en-us/fabric/onelake/onelake-access-api
[git-connect]: https://learn.microsoft.com/en-us/rest/api/fabric/core/git/connect
