package net.meshmapper.app
data class CarMapCoverage(
    val tileUrl: String,
    val fillColorExpression: String,
    val outlineColorExpression: String,
    val opacity: Float,
    val minZoom: Float,
    val maxZoom: Float,
)
