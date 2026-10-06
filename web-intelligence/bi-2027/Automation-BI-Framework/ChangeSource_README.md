# ChangeSource Automation (BI 2027)

This package provides bulk Web Intelligence Change Source automation for BI 2027
using Bruno requests plus Java/PowerShell runners.

## Key runtime rule

The current Java and PowerShell launchers are designed to run from an extracted
Bruno-style folder where environments/my-env.bru is present in the runtime root.

If you execute outside that layout, build a runtime folder as described in:

- ChangeSource/README.md

## Repository source layout

```text
Automation-BI-Framework/
├─ ChangeSource_README.md
└─ ChangeSource/
   ├─ README.md
   ├─ bruno/
   ├─ Powershell/
   └─ java/
```

## What to read next

Use ChangeSource/README.md for:

1. Exact runtime folder composition
2. Where to copy Java/PowerShell files in that runtime folder
3. my-env.bru configuration
4. Bruno/PowerShell/Java execution commands
