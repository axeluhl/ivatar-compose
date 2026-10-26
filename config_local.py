import os

DEBUG = False
SECRET_KEY = os.environ["SECRET_KEY"]

_host = os.environ["IVATAR_HOSTNAME"]
ALLOWED_HOSTS = [_host, "localhost"]
CSRF_TRUSTED_ORIGINS = [f"https://{_host}", f"http://{_host}"]
SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
ALLOWED_EXTERNAL_OPENID_REDIRECT_DOMAINS = [_host, "localhost"]

# never contact gravatar.com for unknown addresses
DEFAULT_GRAVATARPROXY = False
DEFAULT_GRAVATARREDIRECT = False

CACHES = {
    "default": {
        "BACKEND": "django.core.cache.backends.memcached.PyMemcacheCache",
        "LOCATION": ["memcached:11211"],
    },
    "filesystem": {
        "BACKEND": "django.core.cache.backends.filebased.FileBasedCache",
        "LOCATION": "/var/tmp/ivatar_cache",
        "TIMEOUT": 86400,
        "OPTIONS": {"MAX_ENTRIES": 1000000},
    },
}

EMAIL_BACKEND = "django.core.mail.backends.smtp.EmailBackend"
EMAIL_HOST = os.environ.get("EMAIL_HOST", "localhost")
EMAIL_PORT = int(os.environ.get("EMAIL_PORT", "25"))
EMAIL_HOST_USER = os.environ.get("EMAIL_HOST_USER", "")
EMAIL_HOST_PASSWORD = os.environ.get("EMAIL_HOST_PASSWORD", "")
EMAIL_USE_TLS = os.environ.get("EMAIL_USE_TLS", "false").lower() == "true"
