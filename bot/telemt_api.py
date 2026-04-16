import aiohttp
import logging
from typing import Any

logger = logging.getLogger(__name__)


class TelemtAPI:
    def __init__(self, base_url: str, metrics_url: str):
        self.base_url = base_url.rstrip("/")
        self.metrics_url = metrics_url.rstrip("/")
        self._session: aiohttp.ClientSession | None = None

    async def _get_session(self) -> aiohttp.ClientSession:
        if self._session is None or self._session.closed:
            self._session = aiohttp.ClientSession(
                timeout=aiohttp.ClientTimeout(total=10)
            )
        return self._session

    async def get_users(self) -> dict[str, Any] | None:
        try:
            s = await self._get_session()
            async with s.get(f"{self.base_url}/v1/users") as r:
                if r.status == 200:
                    return await r.json()
        except Exception as e:
            logger.warning("Telemt API /v1/users failed: %s", e)
        return None

    async def get_runtime(self) -> dict[str, Any] | None:
        try:
            s = await self._get_session()
            async with s.get(f"{self.base_url}/v1/runtime") as r:
                if r.status == 200:
                    return await r.json()
        except Exception as e:
            logger.warning("Telemt API /v1/runtime failed: %s", e)
        return None

    async def get_uptime(self) -> dict[str, Any] | None:
        try:
            s = await self._get_session()
            async with s.get(f"{self.base_url}/v1/uptime") as r:
                if r.status == 200:
                    return await r.json()
        except Exception as e:
            logger.warning("Telemt API /v1/uptime failed: %s", e)
        return None

    async def get_metrics(self) -> str | None:
        try:
            s = await self._get_session()
            async with s.get(f"{self.metrics_url}/metrics") as r:
                if r.status == 200:
                    return await r.text()
        except Exception as e:
            logger.warning("Telemt metrics failed: %s", e)
        return None

    async def is_alive(self) -> bool:
        try:
            s = await self._get_session()
            async with s.get(
                f"{self.base_url}/v1/uptime",
                timeout=aiohttp.ClientTimeout(total=5),
            ) as r:
                return r.status == 200
        except Exception:
            return False

    async def close(self):
        if self._session and not self._session.closed:
            await self._session.close()
