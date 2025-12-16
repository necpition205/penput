use axum::{
    http::{header::CACHE_CONTROL, HeaderValue, StatusCode},
    routing::get_service,
    Router,
};
use tower_http::{
    services::ServeDir,
    set_header::SetResponseHeaderLayer,
    trace::TraceLayer,
};

/// Build the HTTP router serving embedded static assets.
pub fn build_http_router() -> anyhow::Result<Router> {
    let static_service = get_service(ServeDir::new("static").append_index_html_on_directories(true))
        .handle_error(|err| async move {
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("static file error: {err}"),
            )
        });

    let router = Router::new()
        .fallback_service(static_service)
        .layer(SetResponseHeaderLayer::overriding(
            CACHE_CONTROL,
            HeaderValue::from_static("no-store"),
        ))
        .layer(TraceLayer::new_for_http());

    Ok(router)
}

/// Start the HTTP server on the given port.
pub async fn serve_http(app: Router, port: u16) -> anyhow::Result<()> {
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port)).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
