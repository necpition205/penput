use axum::{
    http::header::CONTENT_TYPE,
    response::{Html, IntoResponse},
    routing::get,
    Router,
};
use tower_http::trace::TraceLayer;

/// Build the HTTP router serving embedded static assets.
pub fn build_http_router() -> anyhow::Result<Router> {
    let router = Router::new()
        .route("/", get(index))
        .route("/style.css", get(style))
        .route("/app.js", get(app_js))
        .layer(TraceLayer::new_for_http());

    Ok(router)
}

/// Start the HTTP server on the given port.
pub async fn serve_http(app: Router, port: u16) -> anyhow::Result<()> {
    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port)).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

async fn index() -> impl IntoResponse {
    let body = Html(include_str!("../static/index.html"));
    ([(CONTENT_TYPE, "text/html; charset=utf-8")], body)
}

async fn style() -> impl IntoResponse {
    (
        [(CONTENT_TYPE, "text/css; charset=utf-8")],
        include_str!("../static/style.css"),
    )
}

async fn app_js() -> impl IntoResponse {
    (
        [(CONTENT_TYPE, "application/javascript; charset=utf-8")],
        include_str!("../static/app.js"),
    )
}

