FROM python:3.13-slim

ARG USERNAME=appuser
ARG USER_UID=1000
ARG USER_GID=1000

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/src \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

RUN groupadd --gid "${USER_GID}" "${USERNAME}" \
    && useradd --uid "${USER_UID}" --gid "${USER_GID}" --create-home "${USERNAME}"

COPY layer/requirements.txt ./layer/requirements.txt

RUN python -m pip install --upgrade pip \
    && python -m pip install --no-cache-dir -r layer/requirements.txt

USER ${USERNAME}

CMD ["sleep", "infinity"]
