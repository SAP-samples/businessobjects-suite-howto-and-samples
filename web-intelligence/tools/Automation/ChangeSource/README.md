# WebI Change Source — PowerShell Quick Start

Bulk-change the universe/data source of Web Intelligence documents via the BI REST API.

---

## Prerequisites

- Access to the SAP BusinessObjects server (Tomcat URL + CMS address)
- A BI user with rights to open the documents **and** use the target universe
- The **SI_ID** of the target data source (see [How to find SI_IDs](#how-to-find-si_ids))
- The **SI_IDs** of the WebI documents to migrate
- Windows PowerShell 5.1 (built-in on Windows 10/11) — no extra install needed

---

## 1 · Clone the repository and prepare the config

```powershell
git clone https://github.com/SAP-samples/businessobjects-suite-howto-and-samples
cd businessobjects-suite-howto-and-samples\web-intelligence\tools\Automation\ChangeSource

# Create your local config from the template (git-ignored)
# The PowerShell launcher expects the env file next to itself
Copy-Item .\bruno\environments\my-env.bru.template .\Powershell\environments\my-env.bru
```

Open `Powershell\environments\my-env.bru` in any text editor and fill in your values:

```text
vars {
  baseUrl: http://myserver:8080        # Tomcat root — do NOT include /biprws
  cms: myserver:6400
  user: alice
  password: mysecretpassword
  auth: secEnterprise                  # secEnterprise | secLDAP | secWinAD | secSAPR3
  targetuniverse: 5406                 # SI_ID of the target data source (see below)
  runnerAction: test                   # start with "test" — change to "change" only after review
  strategyMode: default
  docIds: 5418,5403,62362              # comma-separated WebI document SI_IDs
  logonToken:           # leave blank — filled at runtime by the script
  mappingPayload:        # leave blank — filled at runtime by the script
  mappingStrategies:     # leave blank to use the safe default (see Mapping strategies section)
}
```

> **Where does each launcher look?** The `.bat` files resolve `environments\my-env.bru` relative to their own folder:
> - `Powershell\Run-ChangeSource-PowerShell.bat` → reads `Powershell\environments\my-env.bru`
> - `java\Run-ChangeSource-JavaNoJar.bat` → reads `java\environments\my-env.bru`
>
> The template at `bruno\environments\my-env.bru.template` is the source to copy from. Create one copy per runner you use.
```

### How to find SI_IDs

**Target data source SI_ID**  
In the CMC, go to **Universes**, right-click the universe → **Properties**.  
The **SI_ID** is listed under *General* (e.g. `5406`).

Alternatively, use the BI REST API:

```
GET http://myserver:8080/biprws/infostore?query=SELECT SI_ID,SI_NAME FROM CI_INFOOBJECTS WHERE SI_NAME='My Universe'
```

**WebI document SI_IDs**  
In the CMC or BI Launchpad, open the document → **Properties → General → SI_ID**.  
Or use the REST API:

```
GET http://myserver:8080/raylight/v1/documents
```

This returns a list of documents with their `id` (= SI_ID), `name`, and `folderId`.

---

## 2 · Dry run first

```powershell
cd .\Powershell
.\Run-ChangeSource-PowerShell.bat -Test
```

> The `.bat` automatically resolves the path to `bruno\environments\my-env.bru` relative to its own location — you don't need to `cd` back to the repo root.

The script logs in, opens each document, computes the source mapping, prints the result, and logs off — **it does not save any changes**.  
Documents with multiple queries (data providers) are fully supported — each query is processed individually and reported separately.

Review the output. For each query you should see `[MAP:...] X object mapping(s), 0 not-Ok`. Any `not-Ok` count above zero means some report objects could not be matched to the target — check the target SI_ID and consider using `strategyMode: custom`.

You can override `docIds` for a single run without editing the config:

```powershell
.\Run-ChangeSource-PowerShell.bat -DocIds "5418,5403" -Test
```

---

## 3 · Apply the change

Once the dry run looks correct, run in change mode:

```powershell
.\Run-ChangeSource-PowerShell.bat
```

This applies and saves the new source mapping for every document in `docIds`.

> **Save is automatic and immediate.** As soon as a data provider is successfully changed, the document is saved with no further confirmation. If no data provider was changed (e.g. all mappings failed), the document is not saved. Always keep a backup before running in change mode.

---

## Mapping strategies

The `strategyMode` config value controls how report objects in the source data provider are matched to objects in the target data source.

| `strategyMode` | Behaviour |
|---|---|
| `default` | Server's built-in matching — plain GET, no strategies body sent |
| `custom` | You control the matching rules via the `mappingStrategies` JSON variable |

When `strategyMode: custom` and `mappingStrategies` is blank, the following safe default is used automatically:

```json
{
  "strategies": {
    "strategy": [
      { "name": "SamePath",          "enabled": true  },
      { "name": "SameTechnicalName", "enabled": true  },
      { "name": "SameName",          "enabled": true  },
      { "name": "Removal",           "enabled": false }
    ]
  }
}
```

| Strategy | What it does |
|---|---|
| `SamePath` | Match objects by folder path in the universe |
| `SameTechnicalName` | Match by technical name |
| `SameName` | Match by display name |
| `Removal` | **`false` (recommended)** — unmatched objects are kept in the report. Set to `true` to remove unmatched report objects. |

To override, paste your JSON directly into the `mappingStrategies` line in `my-env.bru`:

```text
mappingStrategies: {"strategies":{"strategy":[{"name":"SamePath","enabled":true},{"name":"Removal","enabled":false}]}}
```

Or pass `-StrategyMode custom` on the command line — the script will use the value from `mappingStrategies` in the config, or fall back to the safe default if it is blank.

> **Note:** strategies are sent on the mapping **compute** request (GET). Sending strategies on the apply request (POST) is rejected by the server with `400 WSR 00103`.

---

## Annex A — Bruno (interactive exploration)

[Bruno](https://www.usebruno.com/) lets you run the requests interactively and inspect each HTTP call.

1. Open the `bruno/` folder as a collection in Bruno.
2. Select the **my-env** environment.
3. Run **`00 - Bulk Change Source (All-in-One)`** — this is equivalent to running the PowerShell script.

Individual step-by-step requests (`01 - Logon.bru` … `07 - Logoff.bru`) are useful for debugging.

---

## Annex B — Java (no JAR)

A JDK (not just a JRE) must be installed and `javac` available on PATH.

```bat
cd ChangeSource\java
Run-ChangeSource-JavaNoJar.bat --test
Run-ChangeSource-JavaNoJar.bat                   # apply
Run-ChangeSource-JavaNoJar.bat --docIds 5418,5403 --test   # override docIds
```

The launcher compiles `java\ChangeSource.java` on first run; compiled classes go into an `out\` folder.

---

## Annex C — What happens internally

1. POST `/biprws/logon/long` → obtain `X-SAP-LogonToken`
2. GET `/raylight/v1/documents/{docId}` for each document
3. GET `/raylight/v1/documents/{docId}/dataproviders` — one call per query in the document
4. Compute source mapping (current source → target data source)
5. POST mapping to apply Change Source
6. PUT empty body to save the document
7. PUT `occurrences/0` to `Unused` to close the document session
8. POST `/biprws/logoff`

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Env file not found` | Confirm `Powershell\environments\my-env.bru` exists (copy from `bruno\environments\my-env.bru.template`). Each launcher reads the env file from its own folder. |
| Logon failed (401) | Check `baseUrl` (no `/biprws`), `cms`, `user`, `password`, `auth` |
| Document not found (404) | Verify the SI_ID in `docIds` |
| Not authorized (403) | The user must be able to open the document and use the target universe |
| Wrong universe mapped | Stop. Verify `targetuniverse` SI_ID in the CMC before running in change mode |
| `javac` not found | Install a JDK (not just a JRE); add `%JAVA_HOME%\bin` to PATH |

