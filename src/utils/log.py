import logging
import os


def get_logger(name: str) -> logging.Logger:
    logger = logging.getLogger(name)
    level_name = os.getenv("LOG_LEVEL", "INFO").upper()
    level = getattr(logging, level_name, logging.INFO)

    logging.getLogger().setLevel(level)
    logger.setLevel(level)

    if not logging.getLogger().handlers:
        logging.basicConfig(
            format="%(asctime)s %(levelname)s %(name)s %(message)s",
            level=level,
        )

    return logger
