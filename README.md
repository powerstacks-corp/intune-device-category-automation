# Intune Device Category Automation

A PowerShell runbook that **automatically assigns the correct Device Category** to Microsoft Intune devices based on their Autopilot or Windows 365 enrollment profile, so admins don't have to set categories by hand for every new device.

The script is designed to run on a schedule in an **Azure Automation account** using a **System Assigned Managed Identity**, authenticating to Microsoft Graph through an Entra ID app registration whose credentials are stored in **Azure Key Vault**.

This repository is published by **PowerStacks** for **BI for Intune** customers and the wider Intune community.

**Companion blog post:** [Automatically Categorize Intune Devices](https://powerstacks.com/blog/automatically-categorize-intune-devices/)

---

## What it does

For each device in a target Entra ID group:

1. Looks up the device in Intune via Microsoft Graph (beta).
2. Reads the device's current Device Category.
3. Compares it to the target category for that group.
4. Assigns or corrects the Device Category if it's missing or wrong.

A typical deployment pairs each Autopilot enrollment profile (or Windows 365 provisioning policy) with a dynamic Entra ID group and a Device Category, then runs the script on a schedule. The blog post walks through the full setup end-to-end.

---

## Prerequisites

- Permissions to create an **Azure App Registration**
- Permissions to create an **Azure Key Vault**
- Permissions to create an **Azure Automation Account** (with a System Assigned Managed Identity)
- Microsoft Graph application permissions on the app registration:
  - `Group.Read.All`
  - `GroupMember.Read.All`
  - `Device.ReadWrite.All`
  - `DeviceManagementManagedDevices.ReadWrite.All`

---

## Configuration

Before running, edit the placeholders in [Set-IntuneDeviceCategory.ps1](Set-IntuneDeviceCategory.ps1):

| Placeholder | What to set |
|---|---|
| `<YOUR VAULT NAME HERE>` | Name of the Azure Key Vault holding the `tenantid`, `clientid`, and `clientsecret` secrets |
| `<YOUR DEVICE CATEGORY NAME HERE>` | The Intune Device Category to assign |
| `<YOUR AZURE AD GROUP NAME HERE>` | The Entra ID group whose members should receive the category |

The Key Vault should contain three manual secrets named exactly `tenantid`, `clientid`, and `clientsecret`. The Automation account's Managed Identity needs the **Key Vault Secrets User** role on the vault.

---

## License

[MIT](LICENSE) - use, modify, and share freely.

## Maintainer

Maintained by **PowerStacks**. Issues and pull requests welcome on the [issue tracker](../../issues).
