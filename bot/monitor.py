import asyncio
import logging
import subprocess

from aiogram import Bot

from config import BotConfig
from telemt_api import TelemtAPI

logger = logging.getLogger(__name__)


class Monitor:
    def __init__(self, bot: Bot, api: TelemtAPI, config: BotConfig):
        self.bot = bot
        self.api = api
        self.config = config
        self.alert_enabled = config.alert_enabled
        self._telemt_fail_count = 0
        self._xray_fail_count = 0

    async def run(self):
        await asyncio.sleep(10)
        while True:
            try:
                await self._check()
            except Exception as e:
                logger.error("Monitor error: %s", e)
            await asyncio.sleep(self.config.monitor_interval)

    async def _check(self):
        telemt_ok = await self.api.is_alive()

        xray_ok = False
        try:
            r = subprocess.run(
                ["systemctl", "is-active", "xray"],
                capture_output=True, text=True, timeout=5,
            )
            xray_ok = r.stdout.strip() == "active"
        except Exception:
            pass

        if telemt_ok:
            if self._telemt_fail_count >= 3 and self.alert_enabled:
                await self._alert("🟢 Telemt is back online")
            self._telemt_fail_count = 0
        else:
            self._telemt_fail_count += 1
            if self._telemt_fail_count == 3 and self.alert_enabled:
                await self._alert("🔴 Telemt is DOWN (3 consecutive failures)")

        if not xray_ok:
            self._xray_fail_count += 1
            if self._xray_fail_count == 3 and self.alert_enabled:
                await self._alert("🔴 Xray tunnel is DOWN on RU server")
                try:
                    subprocess.run(["systemctl", "restart", "xray"], timeout=30)
                    await self._alert("🔄 Xray restart attempted")
                except Exception as e:
                    await self._alert(f"❌ Xray restart failed: {e}")
        else:
            self._xray_fail_count = 0

    async def _alert(self, text: str):
        if self.config.admin_chat_id == 0:
            return
        try:
            await self.bot.send_message(
                chat_id=self.config.admin_chat_id, text=text
            )
        except Exception as e:
            logger.error("Alert send failed: %s", e)
