import io
import logging
import subprocess

import qrcode
from aiogram import Dispatcher, Bot, types
from aiogram.filters import Command

from config import BotConfig
from monitor import Monitor
from telemt_api import TelemtAPI

logger = logging.getLogger(__name__)


def _fmt_bytes(b: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if b < 1024:
            return f"{b:.1f} {unit}"
        b /= 1024
    return f"{b:.1f} PB"


def _fmt_uptime(seconds: int) -> str:
    d, seconds = divmod(int(seconds), 86400)
    h, seconds = divmod(seconds, 3600)
    m, s = divmod(seconds, 60)
    parts = []
    if d:
        parts.append(f"{d}d")
    if h:
        parts.append(f"{h}h")
    if m:
        parts.append(f"{m}m")
    if not parts:
        parts.append(f"{s}s")
    return " ".join(parts)


def _parse_prom(text: str) -> dict[str, float]:
    result = {}
    for line in text.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        try:
            name, _, value = line.rpartition(" ")
            result[name.strip()] = float(value)
        except (ValueError, IndexError):
            continue
    return result


def _xray_active() -> bool:
    try:
        r = subprocess.run(
            ["systemctl", "is-active", "xray"],
            capture_output=True, text=True, timeout=5,
        )
        return r.stdout.strip() == "active"
    except Exception:
        return False


def register_handlers(
    dp: Dispatcher, api: TelemtAPI, config: BotConfig, monitor: Monitor
):

    @dp.message(Command("start"))
    async def cmd_start(message: types.Message):
        text = (
            "🛡️ <b>Telemt Proxy Manager</b>\n\n"
            "/status — proxy &amp; tunnel status\n"
            "/stats — traffic statistics\n"
            "/users — active connections\n"
            "/link — proxy link\n"
            "/qr — QR code\n"
            "/health — diagnostics\n"
            "/alerts — toggle alerts\n\n"
            f"Your chat_id: <code>{message.chat.id}</code>"
        )
        await message.reply(text)

    @dp.message(Command("status"))
    async def cmd_status(message: types.Message):
        alive = await api.is_alive()
        runtime = await api.get_runtime()
        uptime_data = await api.get_uptime()

        emoji = "🟢" if alive else "🔴"
        uptime_str = _fmt_uptime(uptime_data.get("uptime_seconds", 0)) if uptime_data else "—"

        conns = 0
        if runtime:
            conns = runtime.get("data", {}).get("connections", 0)

        xray_ok = _xray_active()

        text = (
            f"📊 <b>Proxy Status</b>\n\n"
            f"{emoji} Telemt: {'online' if alive else 'OFFLINE'} (uptime: {uptime_str})\n"
            f"{'🟢' if xray_ok else '🔴'} Xray tunnel: {'active' if xray_ok else 'DOWN'}\n"
            f"📡 Connections: {conns}\n"
            f"🖥️ EU: <code>{config.eu_server_ip}</code>\n"
            f"🔗 RU: <code>{config.ru_domain}</code>"
        )
        await message.reply(text)

    @dp.message(Command("stats"))
    async def cmd_stats(message: types.Message):
        metrics_text = await api.get_metrics()
        if not metrics_text:
            await message.reply("❌ Could not fetch metrics")
            return

        m = _parse_prom(metrics_text)
        upload = 0.0
        download = 0.0
        conns = 0.0
        for key, val in m.items():
            k = key.split("{")[0]
            if k.endswith("upload_bytes") or k.endswith("traffic_upload"):
                upload += val
            elif k.endswith("download_bytes") or k.endswith("traffic_download"):
                download += val
            elif "connections" in k and "total" in k:
                conns = max(conns, val)

        text = (
            f"📈 <b>Traffic Statistics</b>\n\n"
            f"⬆️ Upload: {_fmt_bytes(upload)}\n"
            f"⬇️ Download: {_fmt_bytes(download)}\n"
            f"📡 Connections: {int(conns)}"
        )
        await message.reply(text)

    @dp.message(Command("users"))
    async def cmd_users(message: types.Message):
        users_data = await api.get_users()
        if not users_data:
            await message.reply("❌ Could not fetch users")
            return

        data = users_data.get("data", [])
        if not data:
            await message.reply("👥 No users configured")
            return

        lines = ["👥 <b>Users</b>\n"]
        for user in data:
            name = user.get("username", "?")
            conns = user.get("connections", 0)
            emoji = "🟢" if conns > 0 else "⚫"
            lines.append(f"{emoji} <b>{name}</b> — {conns} conns")

        await message.reply("\n".join(lines))

    @dp.message(Command("link"))
    async def cmd_link(message: types.Message):
        users_data = await api.get_users()
        if not users_data:
            await message.reply("❌ Could not fetch users")
            return

        data = users_data.get("data", [])
        links = []
        for user in data:
            name = user.get("username", "?")
            user_links = user.get("links", {}).get("tls", [])
            if user_links:
                links.append(f"🔗 <b>{name}</b>:\n<code>{user_links[0]}</code>")

        if not links:
            await message.reply("❌ No TLS links found")
            return

        await message.reply("\n\n".join(links))

    @dp.message(Command("qr"))
    async def cmd_qr(message: types.Message, bot: Bot):
        users_data = await api.get_users()
        if not users_data:
            await message.reply("❌ Could not fetch users")
            return

        data = users_data.get("data", [])
        for user in data:
            user_links = user.get("links", {}).get("tls", [])
            if user_links:
                link = user_links[0]
                name = user.get("username", "?")

                qr = qrcode.make(link)
                buf = io.BytesIO()
                qr.save(buf, format="PNG")
                buf.seek(0)

                await bot.send_photo(
                    chat_id=message.chat.id,
                    photo=types.BufferedInputFile(buf.read(), filename=f"{name}.png"),
                    caption=f"🔗 {name}: <code>{link}</code>",
                )
                return

        await message.reply("❌ No TLS links found")

    @dp.message(Command("health"))
    async def cmd_health(message: types.Message):
        results = []

        telemt_ok = await api.is_alive()
        results.append(f"{'✅' if telemt_ok else '❌'} Telemt API ({config.eu_server_ip})")

        xray_ok = _xray_active()
        results.append(f"{'✅' if xray_ok else '❌'} Xray tunnel (local)")

        try:
            r = subprocess.run(
                ["systemctl", "is-active", "telemt-bot"],
                capture_output=True, text=True, timeout=5,
            )
            results.append(f"{'✅' if r.stdout.strip() == 'active' else '❌'} Bot service")
        except Exception:
            results.append("❓ Bot service check failed")

        try:
            r = subprocess.run(
                ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                 "--connect-timeout", "5", f"https://{config.eu_server_ip}:443"],
                capture_output=True, text=True, timeout=10,
            )
            code = r.stdout.strip()
            results.append(f"{'✅' if code in ('200', '301', '302', '403', '000') else '❌'} EU:443 (HTTP {code})")
        except Exception:
            results.append("❌ EU:443 unreachable")

        try:
            r = subprocess.run(
                ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                 "--connect-timeout", "5", f"http://{config.eu_server_ip}:9091/v1/uptime"],
                capture_output=True, text=True, timeout=10,
            )
            code = r.stdout.strip()
            results.append(f"{'✅' if code == '200' else '❌'} Telemt API :9091 (HTTP {code})")
        except Exception:
            results.append("❌ Telemt API unreachable")

        await message.reply("🏥 <b>Diagnostics</b>\n\n" + "\n".join(results))

    @dp.message(Command("alerts"))
    async def cmd_alerts(message: types.Message):
        monitor.alert_enabled = not monitor.alert_enabled
        state = "ON 🔔" if monitor.alert_enabled else "OFF 🔕"
        await message.reply(f"Alerts: <b>{state}</b>")
