"""Groups of domains the user can switch on or off: apps and AI services."""
from .aibypass.domains import AI_DOMAINS

APP_PRESETS = {
    "youtube": {"title": "YouTube", "domains": ["youtube.com", "youtu.be", "googlevideo.com", "ytimg.com", "youtube-nocookie.com"]},
    "discord": {"title": "Discord", "domains": ["discord.com", "discord.gg", "discordapp.com", "discord.media", "gateway.discord.gg"]},
    "telegram": {"title": "Telegram", "domains": ["telegram.org", "t.me", "telegram.me", "web.telegram.org"]},
    "whatsapp": {"title": "WhatsApp", "domains": ["whatsapp.com", "whatsapp.net"]},
    "instagram": {"title": "Instagram", "domains": ["instagram.com", "cdninstagram.com"]},
    "facebook": {"title": "Facebook", "domains": ["facebook.com", "fbcdn.net"]},
    "twitter": {"title": "X (Twitter)", "domains": ["x.com", "twitter.com", "twimg.com"]},
    "twitch": {"title": "Twitch", "domains": ["twitch.tv", "ttvnw.net", "jtvnw.net"]},
    "steam": {"title": "Steam", "domains": ["steampowered.com", "steamcommunity.com", "steamstatic.com"]},
}


def all_presets():
    """Return {key: {"title", "kind", "domains"}} for apps and AI services."""
    result = {}
    for key, info in APP_PRESETS.items():
        result[key] = {"title": info["title"], "kind": "app", "domains": info["domains"]}
    for key, info in AI_DOMAINS.items():
        result[f"ai-{key}"] = {"title": key.capitalize(), "kind": "ai", "domains": info["domains"]}
    return result
