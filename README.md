# Spectra Self-Hosting

This setup uses `Spectra-Server`, `Spectra-Frontend-VAL26`, a local reverse proxy, and a Cloudflare Quick Tunnel. The tunnel exposes only the reverse proxy; the server ports stay local.

The folders can be anywhere, but keep this layout:

```text
your-folder/
├── Spectra-Self-Hosting/
│   ├── README.md
│   ├── reverse-proxy.js
│   └── start-spectra-tunnel.ps1
├── Spectra-Server/
└── Spectra-Frontend-VAL26/
```

## Install

Install:

- [Git](https://git-scm.com/download/win)
- [Node.js 22](https://nodejs.org/en/download)
- [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/)
- [Spectra Client](https://github.com/ValoSpectra/Spectra-Client)

From `your-folder`, clone the two repositories:

```powershell
git clone https://github.com/ValoSpectra/Spectra-Server.git
git clone https://github.com/nobiiVAL/Spectra-Frontend-VAL26.git
```

Install dependencies:

```powershell
cd .\Spectra-Server
corepack enable
yarn install

cd ..\Spectra-Frontend-VAL26
corepack enable
yarn install
```

## Configure

Create `your-folder\Spectra-Server\.env` from `.env.example` and set:

```env
INSECURE=true
REQUIRE_AUTH_KEY=true
AUTH_KEY=replace-with-a-long-random-value
```

Use the same `AUTH_KEY` in Spectra Client. For a local observer, connect the client to `http://127.0.0.1:5100`.

## Start

Open PowerShell in the `Spectra-Self-Hosting` folder and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\start-spectra-tunnel.ps1
```

The script asks for the group code and whether to build the frontend. Building defaults to `No`. After the inputs, it displays `Booting Spectra...` while starting the services.

The script starts:

1. `Spectra Server`
2. `Spectra Frontend-VAL26`
3. `reverse-proxy.js`
4. `cloudflared`

When the tunnel is ready, the script displays a colored ready message and the public overlay URL:

```text
+------------------------------------------------------------------------------------------+
|  Spectra tunnel ready                                                                   |
|  https://YOUR-QUICK-TUNNEL.trycloudflare.com/overlay?groupCode=YOUR_GROUP_CODE           |
+------------------------------------------------------------------------------------------+
Keep window open. CTRL+C to exit
```

Click or start the following programs before a match:

- Riot Client and VALORANT
- Spectra Client
- The PowerShell launcher above

Press `Ctrl+C` in the launcher window to stop everything. Use `-Build` to skip the build prompt and build automatically.
