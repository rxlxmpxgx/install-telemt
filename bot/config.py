import configparser
from dataclasses import dataclass


@dataclass
class BotConfig:
    bot_token: str
    admin_chat_id: int
    telemt_api_url: str
    telemt_metrics_url: str
    eu_server_ip: str
    ru_domain: str
    monitor_interval: int = 30
    alert_enabled: bool = True

    @classmethod
    def from_file(cls, path: str) -> "BotConfig":
        cp = configparser.ConfigParser()
        cp.read(path)
        api_url = cp.get("telemt", "api_url")
        metrics_url = cp.get("telemt", "metrics_url", fallback="")
        if not metrics_url:
            host_part = api_url.rsplit(":", 1)[0]
            metrics_url = f"{host_part}:9090"
        return cls(
            bot_token=cp.get("bot", "token"),
            admin_chat_id=cp.getint("bot", "admin_chat_id", fallback=0),
            telemt_api_url=api_url,
            telemt_metrics_url=metrics_url,
            eu_server_ip=cp.get("telemt", "eu_server_ip"),
            ru_domain=cp.get("proxy", "ru_domain"),
            monitor_interval=cp.getint("monitor", "interval", fallback=30),
            alert_enabled=cp.getboolean("monitor", "alert_enabled", fallback=True),
        )
