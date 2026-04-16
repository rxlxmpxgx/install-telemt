import asyncio
import logging
import sys
from pathlib import Path

from aiogram import Bot, Dispatcher
from aiogram.enums import ParseMode
from aiogram.client.default import DefaultBotProperties

from config import BotConfig
from handlers import register_handlers
from monitor import Monitor
from telemt_api import TelemtAPI

logger = logging.getLogger(__name__)

CONFIG_PATH = Path("/opt/telemt-project/bot.ini")
if not CONFIG_PATH.exists():
    CONFIG_PATH = Path(__file__).parent / "bot.ini"


async def main():
    config = BotConfig.from_file(str(CONFIG_PATH))

    bot = Bot(
        token=config.bot_token,
        default=DefaultBotProperties(parse_mode=ParseMode.HTML),
    )
    dp = Dispatcher()

    api = TelemtAPI(config.telemt_api_url, config.telemt_metrics_url)
    monitor = Monitor(bot, api, config)

    register_handlers(dp, api, config, monitor)

    asyncio.create_task(monitor.run())

    logger.info("Bot started")
    try:
        await dp.start_polling(bot)
    finally:
        await api.close()
        await bot.session.close()


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, SystemExit):
        pass
