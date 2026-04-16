from http import HTTPStatus


class AppError(Exception):
    error_code = "app_error"
    status_code = HTTPStatus.INTERNAL_SERVER_ERROR
    expose_message = False

    def __init__(
        self,
        message: str,
        *,
        error_code: str | None = None,
        status_code: int | HTTPStatus | None = None,
        expose_message: bool | None = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        if error_code is not None:
            self.error_code = error_code
        if status_code is not None:
            self.status_code = HTTPStatus(status_code)
        if expose_message is not None:
            self.expose_message = expose_message

    @property
    def public_message(self) -> str:
        if self.expose_message:
            return self.message
        return "Unexpected processing error"


class ConfigError(AppError):
    error_code = "config_error"
    status_code = HTTPStatus.INTERNAL_SERVER_ERROR


class ValidationError(AppError):
    error_code = "validation_error"
    status_code = HTTPStatus.BAD_REQUEST
    expose_message = True


class DatabaseError(AppError):
    error_code = "database_error"
    status_code = HTTPStatus.INTERNAL_SERVER_ERROR


class DatabaseConnectionError(DatabaseError):
    error_code = "database_connection_error"


class DatabaseQueryError(DatabaseError):
    error_code = "database_query_error"


class ProcessingError(AppError):
    error_code = "processing_error"
    status_code = HTTPStatus.INTERNAL_SERVER_ERROR
