package com.addvalue.toppicks

import android.content.Context
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.text.style.TextOverflow
import com.addvalue.toppicks.ui.theme.TopPicksTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.time.LocalDateTime
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.round

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            TopPicksTheme(dynamicColor = false) {
                Surface(modifier = Modifier.fillMaxSize(), color = AppBackground) {
                    TopPicksApp()
                }
            }
        }
    }
}

private data class StockPick(
    val code: String,
    val name: String,
    val price: String,
    val changeRate: Double,
    val tradingValue: Long,
    val marketCap: Long = 0,
    val score: Double = 0.0,
    val targetUpside: Double? = null,
    val targetPrice: Double? = null,
    val stopPrice: Double? = null,
    val stopRate: Double? = null,
    val reportCount: Int = 0,
    val per: Double? = null,
    val pbr: Double? = null,
    val baseScore: Double = 0.0,
    val liquid: Boolean = false,
    val reasons: List<String> = emptyList(),
    val details: List<String> = emptyList(),
    val newsSummary: List<String> = emptyList(),
    val market: String = "",
    val shortTermScore: Double = 0.0,
    val longTermScore: Double = 0.0
)

private data class MarketIndex(
    val name: String,
    val price: String,
    val changeRate: Double
)

private data class PicksData(
    val kospiIndex: MarketIndex,
    val kosdaqIndex: MarketIndex,
    val kospi: List<StockPick>,
    val kosdaq: List<StockPick>,
    val marketStatus: String,
    val updatedAt: String,
    val recordable: Boolean
)

private data class SavedPick(
    val date: String,
    val market: String,
    val code: String,
    val name: String,
    val entryPrice: Double,
    val score: Double,
    val targetPrice: Double? = null,
    val stopPrice: Double? = null,
    val indexEntry: Double
)

private data class PerformanceRow(
    val pick: SavedPick,
    val currentPrice: Double,
    val returnRate: Double,
    val excessReturn: Double,
    val tradingDays: Int,
    val horizonLabel: String
)

private data class PerformanceResult(
    val rows: List<PerformanceRow>,
    val failedCount: Int
)

private data class KiwoomSnapshot(
    val per: Double?,
    val pbr: Double?,
    val dailyPrices: List<Double>,
    val dailyTradingValues: List<Double>,
    val foreignerBuys: List<Double>,
    val institutionBuys: List<Double>,
    val dartAvailable: Boolean,
    val dartDebtRatio: Double?,
    val dartOperatingProfit: Double?,
    val dartRiskPenalty: Double,
    val dartReasons: List<String>
)

private const val ProxyBaseUrl = "http://127.0.0.1:8787"
private const val TelegramBotToken = "YOUR_BOT_TOKEN" // 텔레그램 봇 토큰 입력
private const val TelegramChatId = "YOUR_CHAT_ID"     // 텔레그램 채널/채팅 ID 입력

private sealed interface ScreenState {
    data class Loading(val progress: Float, val message: String) : ScreenState
    data class Success(val data: PicksData) : ScreenState
    data class Error(val message: String) : ScreenState
}

@Composable
private fun TopPicksApp() {
    val context = LocalContext.current
    var state: ScreenState by remember {
        mutableStateOf(ScreenState.Loading(0f, "필수 데이터 서버 연결을 준비하고 있습니다."))
    }
    var refreshKey by remember { mutableIntStateOf(0) }
    var showPerformance by remember { mutableStateOf(false) }
    var performanceResult by remember { mutableStateOf(PerformanceResult(emptyList(), 0)) }
    var performanceLoading by remember { mutableStateOf(false) }

    LaunchedEffect(refreshKey) {
        // 데이터가 이미 있는 경우(Success)에는 풀스크린 로딩을 띄우지 않음 (Silent Refresh)
        if (state !is ScreenState.Success) {
            state = ScreenState.Loading(0f, "필수 데이터 서버 연결을 확인하고 있습니다.")
        }

        try {
            val data = loadPicks { progress, message ->
                if (state !is ScreenState.Success) {
                    state = ScreenState.Loading(progress, message)
                }
            }
            saveRecommendations(context, data)
            processNotifications(context, data)
            state = ScreenState.Success(data)
        } catch (e: Exception) {
            // 이미 데이터가 있다면 에러 화면으로 전환하지 않고 기존 데이터 유지 (안정성)
            if (state !is ScreenState.Success) {
                state = ScreenState.Error(e.message ?: "데이터를 불러오지 못했습니다.")
            }
        }
    }

    // 60초 자동 갱신 타이머
    LaunchedEffect(Unit) {
        while (true) {
            delay(60_000) // 1분마다 자동 실행
            refreshKey++
        }
    }

    LaunchedEffect(showPerformance) {
        if (showPerformance) {
            performanceLoading = true
            performanceResult = loadPerformance(context)
            performanceLoading = false
        }
    }

    when (val current = state) {
        is ScreenState.Loading -> LoadingScreen(current.progress, current.message)
        is ScreenState.Error -> ErrorScreen(current.message) { refreshKey++ }
        is ScreenState.Success -> if (showPerformance) {
            PerformanceScreen(performanceResult, performanceLoading) { showPerformance = false }
        } else {
            PicksScreen(
                data = current.data,
                onRefresh = { refreshKey++ },
                onPerformance = { showPerformance = true }
            )
        }
    }
}

@Composable
private fun LoadingScreen(progress: Float, message: String) {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(
                "${(progress * 100).toInt()}%",
                color = BrandBlue,
                fontSize = 30.sp,
                fontWeight = FontWeight.ExtraBold
            )
            Spacer(Modifier.height(12.dp))
            LinearProgressIndicator(
                progress = { progress },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 36.dp),
                color = BrandBlue,
                trackColor = RankBackground
            )
            Spacer(Modifier.height(16.dp))
            Text(message, color = MutedText)
            Spacer(Modifier.height(6.dp))
            Text("앱을 종료하지 말고 잠시 기다려 주세요.", color = MutedText, fontSize = 12.sp)
        }
    }
}

@Composable
private fun ErrorScreen(message: String, onRetry: () -> Unit) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .padding(28.dp),
        contentAlignment = Alignment.Center
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text("데이터 연결 실패", fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(8.dp))
            Text(message, color = MutedText)
            Spacer(Modifier.height(20.dp))
            Button(onClick = onRetry, colors = ButtonDefaults.buttonColors(BrandBlue)) {
                Text("다시 불러오기")
            }
        }
    }
}

@Composable
private fun PicksScreen(data: PicksData, onRefresh: () -> Unit, onPerformance: () -> Unit) {
    val allStocks = remember(data) { (data.kospi + data.kosdaq).distinctBy { it.code } }
    val shortTermPicks = remember(data) { allStocks.sortedByDescending { it.shortTermScore }.take(15) }
    val longTermPicks = remember(data) { allStocks.sortedByDescending { it.longTermScore }.take(15) }
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        "TODAY'S TOP PICKS",
                        color = BrandBlue,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 1.5.sp
                    )
                    Text("오늘의 종목 추천", fontSize = 28.sp, fontWeight = FontWeight.ExtraBold)
                    Text(data.updatedAt, color = MutedText, fontSize = 13.sp)
                }
                Column(
                    horizontalAlignment = Alignment.End,
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Button(
                        onClick = onPerformance,
                        modifier = Modifier
                            .width(104.dp)
                            .height(48.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = BrandBlue)
                    ) {
                        Text("성과 검증")
                    }
                    Button(
                        onClick = onRefresh,
                        modifier = Modifier
                            .width(104.dp)
                            .height(48.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = CardBackground,
                            contentColor = BrandBlue
                        )
                    ) {
                        Text("새로고침")
                    }
                }
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                IndexCard(data.kospiIndex, Modifier.weight(1f))
                IndexCard(data.kosdaqIndex, Modifier.weight(1f))
            }
        }
        item {
            Text(
                data.marketStatus,
                modifier = Modifier
                    .fillMaxWidth()
                    .background(InfoBackground, RoundedCornerShape(12.dp))
                    .padding(14.dp),
                color = BrandBlue,
                fontSize = 13.sp
            )
        }
        item {
            MarketTitle("단기", "단기 상승 예상 종목")
            Text(
                "수급·가격 추세·손익비 등 단기 모멘텀 지표가 강한 종목입니다. (코스피·코스닥 통합)",
                color = MutedText,
                fontSize = 12.sp,
                modifier = Modifier.padding(top = 6.dp)
            )
        }
        itemsIndexed(shortTermPicks) { index, stock ->
            StockCard(index + 1, stock, horizon = "단기")
        }
        item {
            Spacer(Modifier.height(8.dp))
            MarketTitle("장기", "장기 상승 예상 종목")
            Text(
                "실적 전망·리포트 목표가·재무 안정성·저평가 등 펀더멘털 지표가 우수한 종목입니다. (코스피·코스닥 통합)",
                color = MutedText,
                fontSize = 12.sp,
                modifier = Modifier.padding(top = 6.dp)
            )
        }
        itemsIndexed(longTermPicks) { index, stock ->
            StockCard(index + 1, stock, horizon = "장기")
        }
        item {
            Text(
                "추천은 리포트 목표가·전망 변경, 컨센서스 실적, 밸류에이션, 외국인·기관 수급과 위험 요인을 종합한 참고 정보이며 투자 수익을 보장하지 않습니다.",
                color = MutedText,
                fontSize = 11.sp,
                lineHeight = 17.sp,
                modifier = Modifier.padding(vertical = 10.dp)
            )
        }
    }
}

@Composable
private fun PerformanceScreen(
    result: PerformanceResult,
    loading: Boolean,
    onBack: () -> Unit
) {
    val rows = result.rows
    val average = rows.map { it.returnRate }.averageOrZero()
    val excess = rows.map { it.excessReturn }.averageOrZero()
    val hitRate = if (rows.isEmpty()) 0.0 else rows.count { it.returnRate > 0 } * 100.0 / rows.size

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("PERFORMANCE", color = BrandBlue, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                    Text("추천 성과 검증", fontSize = 28.sp, fontWeight = FontWeight.ExtraBold)
                }
                Button(onClick = onBack, colors = ButtonDefaults.buttonColors(BrandBlue)) {
                    Text("오늘 추천")
                }
            }
        }
        if (loading) {
            item { CircularProgressIndicator(color = BrandBlue) }
        } else if (rows.isEmpty()) {
            item {
                Text(
                    "저장된 추천 이력이 없습니다. 오늘 추천을 확인하면 자동으로 기록됩니다.",
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(CardBackground, RoundedCornerShape(16.dp))
                        .padding(20.dp),
                    color = MutedText
                )
            }
        } else {
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    MetricCard("평균 수익률", formatRate(average), Modifier.weight(1f))
                    MetricCard("시장 대비", formatRate(excess), Modifier.weight(1f))
                    MetricCard("적중률", "%.1f%%".format(hitRate), Modifier.weight(1f))
                }
            }
            item {
                Text(
                    "D+1/D+2/D+3 evaluation ${rows.size} rows · failed ${result.failedCount} · net of costs",
                    color = MutedText,
                    fontSize = 12.sp
                )
            }
            itemsIndexed(rows.sortedByDescending { it.pick.date }) { _, row ->
                PerformanceCard(row)
            }
        }
    }
}

@Composable
private fun MetricCard(label: String, value: String, modifier: Modifier) {
    Column(
        modifier = modifier
            .background(CardBackground, RoundedCornerShape(14.dp))
            .padding(12.dp)
    ) {
        Text(label, color = MutedText, fontSize = 11.sp)
        Text(value, color = BrandBlue, fontWeight = FontWeight.Bold, fontSize = 16.sp)
    }
}

@Composable
private fun PerformanceCard(row: PerformanceRow) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(CardBackground, RoundedCornerShape(16.dp))
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(row.pick.name, fontWeight = FontWeight.Bold)
            Text(
                "${row.pick.date} · ${row.pick.market} · ${row.horizonLabel}",
                color = MutedText,
                fontSize = 12.sp
            )
            Text(
                "추천 ${row.pick.entryPrice.toInt()}원 → 평가 ${row.currentPrice.toInt()}원",
                color = MutedText,
                fontSize = 12.sp
            )
        }
        Column(horizontalAlignment = Alignment.End) {
            Text(formatRate(row.returnRate), color = rateColor(row.returnRate), fontWeight = FontWeight.Bold)
            Text("초과 ${formatRate(row.excessReturn)}", color = MutedText, fontSize = 12.sp)
        }
    }
}

@Composable
private fun IndexCard(index: MarketIndex, modifier: Modifier = Modifier) {
    val color = rateColor(index.changeRate)
    Column(
        modifier = modifier
            .background(CardBackground, RoundedCornerShape(18.dp))
            .padding(16.dp)
    ) {
        Text(index.name, color = MutedText, fontSize = 12.sp)
        Spacer(Modifier.height(5.dp))
        Text(index.price, fontSize = 20.sp, fontWeight = FontWeight.Bold)
        Text(formatRate(index.changeRate), color = color, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun MarketTitle(label: String, title: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(
            label,
            color = Color.White,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            modifier = Modifier
                .background(BrandBlue, RoundedCornerShape(7.dp))
                .padding(horizontal = 8.dp, vertical = 4.dp)
        )
        Spacer(Modifier.width(8.dp))
        Text(title, fontSize = 20.sp, fontWeight = FontWeight.Bold)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun StockCard(rank: Int, stock: StockPick, horizon: String = "") {
    val horizonScore = when (horizon) {
        "단기" -> stock.shortTermScore
        "장기" -> stock.longTermScore
        else -> stock.score
    }
    var expanded by remember { mutableStateOf(false) }
    val rotation by animateFloatAsState(if (expanded) 180f else 0f)

    // 진입 상태 판별 로직
    val targetRate = (stock.targetUpside?.div(3.0) ?: 4.0).coerceIn(2.5, 8.0)
    val stopRate = stock.stopRate ?: 4.0
    val rewardRisk = targetRate / stopRate

    val (statusText, statusColor, statusBg) = when {
        stock.score >= 82 && rewardRisk >= 1.8 && stock.changeRate > -3.0 ->
            Triple("진입 적격", Color(0xFFE44755), Color(0xFFFFEBEE))
        stock.score >= 70 && stock.changeRate > -4.0 ->
            Triple("진입 가능", BrandBlue, Color(0xFFE8EDFF))
        else ->
            Triple("관망/조정", MutedText, AppBackground)
    }

    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { expanded = !expanded },
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = CardBackground),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp)
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                // 순위 표시 (박스 제거, 심플 텍스트)
                Text(
                    rank.toString(),
                    color = BrandBlue,
                    fontWeight = FontWeight.ExtraBold,
                    fontSize = 20.sp,
                    modifier = Modifier.width(28.dp)
                )

                // 진입 상태 배지
                Text(
                    statusText,
                    modifier = Modifier
                        .background(statusBg, RoundedCornerShape(8.dp))
                        .padding(horizontal = 8.dp, vertical = 4.dp),
                    color = statusColor,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold
                )

                Spacer(Modifier.width(12.dp))

                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        stock.name,
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        "${stock.market} · ${stock.code} · 리포트 ${stock.reportCount}건",
                        color = MutedText,
                        fontSize = 12.sp
                    )
                }

                Column(horizontalAlignment = Alignment.End) {
                    Text(
                        "${horizonScore.toInt()}점",
                        color = BrandBlue,
                        fontSize = 20.sp,
                        fontWeight = FontWeight.Black
                    )
                    Text(
                        stock.targetUpside?.let { (if (it > 0) "▲" else "▼") + formatRate(it) } ?: "산출 불가",
                        color = stock.targetUpside?.let(::rateColor) ?: MutedText,
                        fontWeight = FontWeight.Bold,
                        fontSize = 13.sp
                    )
                }
                Icon(
                    imageVector = KeyboardArrowDown,
                    contentDescription = null,
                    modifier = Modifier
                        .rotate(rotation)
                        .padding(start = 8.dp),
                    tint = MutedText
                )
            }

            if (stock.reasons.isNotEmpty()) {
                Spacer(Modifier.height(12.dp))
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    stock.reasons.forEach { reason ->
                        ReasonTag(reason)
                    }
                }
            }

            AnimatedVisibility(visible = expanded) {
                Column {
                    Spacer(Modifier.height(16.dp))
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(1.dp)
                            .background(AppBackground)
                    )
                    Spacer(Modifier.height(16.dp))

                    Text(
                        "단기 ${stock.shortTermScore.toInt()}점 · 장기 ${stock.longTermScore.toInt()}점 · 종합 ${stock.score.toInt()}점",
                        color = MutedText,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold
                    )
                    Spacer(Modifier.height(12.dp))

                    if (stock.targetPrice != null && stock.stopPrice != null) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            PriceInfo("목표가", stock.targetPrice, BrandBlue)
                            PriceInfo("손절가", stock.stopPrice, RisingRed)
                        }
                        Spacer(Modifier.height(12.dp))
                    }

                    stock.details.forEach { detail ->
                        Row(modifier = Modifier.padding(vertical = 4.dp)) {
                            Text("•", color = BrandBlue, modifier = Modifier.padding(end = 8.dp))
                            Text(
                                detail,
                                color = Color(0xFF4E5668),
                                fontSize = 13.sp,
                                lineHeight = 20.sp
                            )
                        }
                    }

                    if (stock.newsSummary.isNotEmpty()) {
                        Spacer(Modifier.height(12.dp))
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(1.dp)
                                .background(AppBackground)
                        )
                        Spacer(Modifier.height(12.dp))
                        Text(
                            "상승 예상 근거 (증권사 리포트·뉴스)",
                            color = BrandBlue,
                            fontWeight = FontWeight.Bold,
                            fontSize = 13.sp
                        )
                        Spacer(Modifier.height(6.dp))
                        stock.newsSummary.forEach { news ->
                            Row(modifier = Modifier.padding(vertical = 4.dp)) {
                                Text("•", color = BrandBlue, modifier = Modifier.padding(end = 8.dp))
                                Text(
                                    news,
                                    color = Color(0xFF4E5668),
                                    fontSize = 12.5.sp,
                                    lineHeight = 19.sp
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ReasonTag(text: String) {
    val bgColor = when {
        "수급" in text || "매수" in text -> Color(0xFFE3F2FD)
        "저평가" in text || "밸류" in text -> Color(0xFFF1F8E9)
        "위험" in text || "감점" in text -> Color(0xFFFFF3E0)
        else -> InfoBackground
    }
    val textColor = when {
        "수급" in text || "매수" in text -> Color(0xFF1976D2)
        "저평가" in text || "밸류" in text -> Color(0xFF388E3C)
        "위험" in text || "감점" in text -> Color(0xFFE64A19)
        else -> BrandBlue
    }

    Text(
        text,
        modifier = Modifier
            .background(bgColor, RoundedCornerShape(8.dp))
            .padding(horizontal = 8.dp, vertical = 4.dp),
        color = textColor,
        fontSize = 11.sp,
        fontWeight = FontWeight.Bold
    )
}

@Composable
private fun PriceInfo(label: String, price: Double, color: Color) {
    Column {
        Text(label, color = MutedText, fontSize = 11.sp)
        Text(formatWon(price), color = color, fontWeight = FontWeight.Bold, fontSize = 15.sp)
    }
}

private suspend fun loadPicks(
    onProgress: (Float, String) -> Unit
): PicksData = withContext(Dispatchers.IO) {
    onProgress(0.03f, "키움·DART 데이터 서버 연결을 확인하고 있습니다.")
    if (!isKiwoomProxyAvailable()) {
        throw IllegalStateException(
            "필수 데이터 서버에 연결할 수 없습니다. PC에서 kiwoom_proxy.ps1을 실행하고 다시 시도해 주세요."
        )
    }
    onProgress(0.08f, "시장 지수와 추천 후보를 수집하고 있습니다.")
    val kospiIndex = fetchIndex("KOSPI")
    val kosdaqIndex = fetchIndex("KOSDAQ")
    val kospiResult = fetchStocks("KOSPI") { completed, total ->
        onProgress(
            0.10f + completed.toFloat() / total.coerceAtLeast(1) * 0.40f,
            "코스피 종목 심층 분석 중 ($completed/$total)"
        )
    }
    val kosdaqResult = fetchStocks("KOSDAQ") { completed, total ->
        onProgress(
            0.50f + completed.toFloat() / total.coerceAtLeast(1) * 0.45f,
            "코스닥 종목 심층 분석 중 ($completed/$total)"
        )
    }
    if (kospiResult.first.size < 7 || kosdaqResult.first.size < 7) {
        throw IllegalStateException("필수 데이터가 완전한 추천 종목을 시장별 7개 확보하지 못했습니다.")
    }
    onProgress(0.98f, "추천 점수와 검증 정보를 정리하고 있습니다.")
    val isLive = kospiResult.second == "OPEN" || kosdaqResult.second == "OPEN"

    PicksData(
        kospiIndex = kospiIndex,
        kosdaqIndex = kosdaqIndex,
        kospi = kospiResult.first,
        kosdaq = kosdaqResult.first,
        marketStatus = if (isLive) {
            "종합 분석: 목표가 상승 여력, 이익 전망, 저평가, 수급과 위험을 반영한 순위입니다."
        } else {
            "장외 종합 분석: 최근 종가와 리포트·컨센서스·수급 데이터를 반영한 순위입니다."
        },
        updatedAt = LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyy.MM.dd HH:mm 기준"))
        ,
        recordable = kospiResult.second != "PREOPEN" && kosdaqResult.second != "PREOPEN"
    )
}

private fun fetchIndex(market: String): MarketIndex {
    val rows = JSONArray(getJson("https://m.stock.naver.com/api/index/$market/price"))
    val item = rows.getJSONObject(0)
    return MarketIndex(
        name = market,
        price = item.optString("closePrice", "-"),
        changeRate = item.optString("fluctuationsRatio", "0").numberValue()
    )
}

private fun saveRecommendations(context: Context, data: PicksData) {
    if (!data.recordable || data.kospi.isEmpty() || data.kosdaq.isEmpty()) return
    val date = LocalDateTime.now().toLocalDate().toString()
    val preferences = context.getSharedPreferences("recommendation_history", Context.MODE_PRIVATE)
    val existing = runCatching { JSONArray(preferences.getString("items", "[]")) }.getOrDefault(JSONArray())

    val output = JSONArray()
    for (index in 0 until existing.length()) {
        val item = existing.optJSONObject(index)
        if (item?.optString("date") != date) output.put(existing.get(index))
    }
    fun append(market: String, stocks: List<StockPick>, indexPrice: String) {
        stocks.forEach { stock ->
            output.put(
                JSONObject()
                    .put("date", date)
                    .put("market", market)
                    .put("code", stock.code)
                    .put("name", stock.name)
                    .put("entryPrice", stock.price.numberValue())
                    .put("score", stock.score)
                    .put("targetPrice", stock.targetPrice)
                    .put("stopPrice", stock.stopPrice)
                    .put("indexEntry", indexPrice.numberValue())
            )
        }
    }
    append("KOSPI", data.kospi, data.kospiIndex.price)
    append("KOSDAQ", data.kosdaq, data.kosdaqIndex.price)
    while (output.length() > 2_000) output.remove(0)
    preferences.edit().putString("items", output.toString()).apply()
}

private suspend fun processNotifications(context: Context, data: PicksData) {
    if (TelegramBotToken == "YOUR_BOT_TOKEN") return
    val date = LocalDateTime.now().toLocalDate().toString()
    val logPrefs = context.getSharedPreferences("notification_log", Context.MODE_PRIVATE)
    val historyPrefs = context.getSharedPreferences("recommendation_history", Context.MODE_PRIVATE)
    val todayPicks = runCatching { JSONArray(historyPrefs.getString("items", "[]")) }.getOrDefault(JSONArray())

    val allCurrentStocks = data.kospi + data.kosdaq
    allCurrentStocks.forEach { stock ->
        val currentPrice = stock.price.numberValue()

        // 1. 진입 후보 알림 (Entry)
        val targetRate = (stock.targetUpside?.div(3.0) ?: 4.0).coerceIn(2.5, 8.0)
        val rewardRisk = targetRate / (stock.stopRate ?: 4.0)
        val isEntry = (stock.score >= 82 && rewardRisk >= 1.8 && stock.changeRate > -3.0) ||
                      (stock.score >= 70 && stock.changeRate > -4.0)

        if (isEntry) {
            val entryKey = "entry_${date}_${stock.code}"
            if (!logPrefs.contains(entryKey)) {
                val status = if (stock.score >= 82) "진입 적격" else "진입 가능"
                val msg = "[TopPicks $status]\n종목: ${stock.name}(${stock.code})\n점수: ${stock.score.toInt()}점\n현재가: ${stock.price}원(${formatRate(stock.changeRate)})"
                if (sendTelegramMessage(msg)) {
                    logPrefs.edit().putBoolean(entryKey, true).apply()
                }
            }
        }

        // 2. 손절가 도달 알림 (Stop-loss)
        for (i in 0 until todayPicks.length()) {
            val pick = todayPicks.optJSONObject(i)
            if (pick?.optString("date") == date && pick.optString("code") == stock.code) {
                val savedStopPrice = pick.optDouble("stopPrice", 0.0)
                if (savedStopPrice > 0 && currentPrice <= savedStopPrice) {
                    val stopKey = "stop_${date}_${stock.code}"
                    if (!logPrefs.contains(stopKey)) {
                        val msg = "[TopPicks 손절 경고]\n종목: ${stock.name}(${stock.code})\n현재가: ${stock.price}원\n확정 손절가: ${savedStopPrice.toInt()}원\n즉시 대응이 필요합니다."
                        if (sendTelegramMessage(msg)) {
                            logPrefs.edit().putBoolean(stopKey, true).apply()
                        }
                    }
                }
                break
            }
        }
    }
}

private suspend fun sendTelegramMessage(text: String): Boolean = withContext(Dispatchers.IO) {
    runCatching {
        val urlString = "https://api.telegram.org/bot$TelegramBotToken/sendMessage?chat_id=$TelegramChatId&text=${java.net.URLEncoder.encode(text, "UTF-8")}"
        val connection = URL(urlString).openConnection() as HttpURLConnection
        connection.requestMethod = "GET"
        connection.connectTimeout = 5000
        connection.readTimeout = 5000
        val responseCode = connection.responseCode
        connection.disconnect()
        responseCode == 200
    }.getOrDefault(false)
}

private suspend fun loadPerformance(context: Context): PerformanceResult = withContext(Dispatchers.IO) {
    val preferences = context.getSharedPreferences("recommendation_history", Context.MODE_PRIVATE)
    val array = runCatching { JSONArray(preferences.getString("items", "[]")) }.getOrDefault(JSONArray())
    val saved = (0 until array.length()).mapNotNull { index ->
        array.optJSONObject(index)?.let {
            SavedPick(
                date = it.optString("date"),
                market = it.optString("market"),
                code = it.optString("code"),
                name = it.optString("name"),
                entryPrice = it.optDouble("entryPrice"),
                score = it.optDouble("score"),
                targetPrice = it.optNullableDouble("targetPrice"),
                stopPrice = it.optNullableDouble("stopPrice"),
                indexEntry = it.optDouble("indexEntry")
            )
        }
    }
    val results = saved.map { pick ->
        runCatching {
                    val history = JSONObject(
                        getJson("$ProxyBaseUrl/history/${pick.code}/${pick.market}")
                    )
                    val stockHistory = parseHistory(history.optJSONArray("stockHistory"))
                        .filter { it.first > pick.date }
                        .sortedBy { it.first }
                    val indexHistory = parseHistory(history.optJSONArray("indexHistory"))
                    availableHorizons(stockHistory.size).mapNotNull { horizon ->
                        val evaluationDate = stockHistory[horizon - 1].first
                        val evaluationPrice = stockHistory[horizon - 1].second
                        val currentIndex = indexHistory.firstOrNull { it.first == evaluationDate }?.second
                            ?: indexHistory.lastOrNull { it.first <= evaluationDate }?.second
                            ?: return@mapNotNull null
                        val stockReturn = calculateReturn(pick.entryPrice, evaluationPrice)
                        val indexReturn = calculateReturn(pick.indexEntry, currentIndex)
                        PerformanceRow(
                            pick = pick,
                            currentPrice = evaluationPrice,
                            returnRate = stockReturn,
                            excessReturn = stockReturn - indexReturn,
                            tradingDays = horizon,
                            horizonLabel = "D+$horizon"
                        )
                    }
                }.getOrNull()
    }
    PerformanceResult(
        rows = results.filterNotNull().flatten(),
        failedCount = results.count { it == null }
    )
}

private fun List<Double>.averageOrZero(): Double = if (isEmpty()) 0.0 else average()

internal fun calculateReturn(entry: Double, exit: Double): Double =
    if (entry > 0) (exit - entry) / entry * 100.0 else 0.0

internal fun availableHorizons(tradingDayCount: Int): List<Int> =
    listOf(1, 2, 3).filter { tradingDayCount >= it }

private fun parseHistory(rows: JSONArray?): List<Pair<String, Double>> {
    if (rows == null) return emptyList()
    return (0 until rows.length()).mapNotNull { index ->
        val item = rows.optJSONObject(index) ?: return@mapNotNull null
        val date = item.optString("localTradedAt")
        val price = item.optString("closePrice").numberValue()
        if (date.isBlank() || price <= 0) null else date to price
    }
}

private suspend fun fetchStocks(
    market: String,
    onAnalyzed: (Int, Int) -> Unit
): Pair<List<StockPick>, String> {
    val rising = JSONObject(
        getJson("https://m.stock.naver.com/api/stocks/up/$market?page=1&pageSize=50")
    )
    val status = rising.optString("marketStatus", "")
    val risingStocks = parseStocks(rising.optJSONArray("stocks") ?: JSONArray())
    val representativeStocks = (1..5).flatMap { page ->
        val marketValue = JSONObject(
            getJson("https://m.stock.naver.com/api/stocks/marketValue/$market?page=$page&pageSize=50")
        )
        parseStocks(marketValue.optJSONArray("stocks") ?: JSONArray())
    }
    val minimumMarketCap = if (market == "KOSPI") 5_000L else 3_000L
    val risingCandidates = risingStocks
        .distinctBy { it.code }
        .filter { it.marketCap >= minimumMarketCap }
        .sortedByDescending { preliminaryScore(it) }
        .take(25)
    val activeCandidates = representativeStocks
        .distinctBy { it.code }
        .filter { it.marketCap >= minimumMarketCap }
        .sortedByDescending { it.tradingValue }
        .take(30)
    val stableCandidates = representativeStocks
        .distinctBy { it.code }
        .filter {
            it.marketCap >= minimumMarketCap &&
                it.tradingValue > 0 &&
                abs(it.changeRate) <= 3.0
        }
        .sortedByDescending { it.tradingValue }
        .take(25)
    val candidates = (risingCandidates + activeCandidates + stableCandidates).distinctBy { it.code }
    val analyzed = analyzeCandidates(candidates, onAnalyzed)
    val scoringPool = analyzed.filter { it.liquid }
    val medianPer = scoringPool.mapNotNull { it.per }.filter { it > 0 }.median()
    val medianPbr = scoringPool.mapNotNull { it.pbr }.filter { it > 0 }.median()

    return scoringPool
        .map { stock ->
            val valuationScore =
                relativeValueScore(stock.per, medianPer) + relativeValueScore(stock.pbr, medianPbr)
            stock.copy(
                market = market,
                score = (stock.baseScore + valuationScore).coerceIn(0.0, 100.0),
                longTermScore = (stock.longTermScore + valuationScore).coerceIn(0.0, 100.0),
                reasons = stock.reasons + if (valuationScore >= 6.0) {
                    listOf("후보군 대비 저평가")
                } else {
                    emptyList()
                },
                details = stock.details + "밸류에이션 ${valuationScore.toInt()}/10점: PER ${
                    stock.per?.let { "%.1f".format(it) } ?: "-"
                }배, PBR ${stock.pbr?.let { "%.1f".format(it) } ?: "-"}배"
            )
        }
        .sortedByDescending { it.score }
        .take(20) to status
}

private fun parseStocks(array: JSONArray): List<StockPick> = buildList {
    for (index in 0 until array.length()) {
        val item = array.getJSONObject(index)
        add(
            StockPick(
                code = item.optString("itemCode"),
                name = item.optString("stockName"),
                price = item.optString("closePrice", "-"),
                changeRate = item.optString("fluctuationsRatio", "0").toDoubleOrNull() ?: 0.0,
                tradingValue = item.optString("accumulatedTradingValue", "0")
                    .replace(",", "")
                    .toLongOrNull() ?: 0L,
                marketCap = item.optString("marketValue", "0")
                    .replace(",", "")
                    .toLongOrNull() ?: 0L
            )
        )
    }
}

private fun preliminaryScore(stock: StockPick): Double =
    stock.changeRate * 3.0 + if (stock.tradingValue > 0) ln(stock.tradingValue.toDouble()) else 0.0

private suspend fun analyzeCandidates(
    candidates: List<StockPick>,
    onAnalyzed: (Int, Int) -> Unit
): List<StockPick> = coroutineScope {
    var completed = 0
    // 서버 부하 분산을 위해 청크 크기를 5에서 3으로 조절 (타임아웃 방지)
    candidates.chunked(3).flatMap { chunk ->
        val results = chunk.map { stock ->
            async(Dispatchers.IO) {
                runCatching { analyzeStock(stock) }.getOrNull()
            }
        }.awaitAll()
        completed += results.size
        onAnalyzed(completed, candidates.size)
        results.filterNotNull()
    }
}

private fun analyzeStock(stock: StockPick): StockPick {
    val kiwoom = fetchKiwoomSnapshot(stock.code)
    require(kiwoom.dartAvailable) { "DART data unavailable for ${stock.code}" }
    val reports = JSONArray(getJson("https://m.stock.naver.com/api/research/stock/${stock.code}"))
    val finance = runCatching {
        JSONObject(getJson("https://m.stock.naver.com/api/stock/${stock.code}/finance/quarter"))
    }.getOrElse {
        JSONObject(getJson("https://m.stock.naver.com/api/stock/${stock.code}/finance/annual"))
    }
    val currentPrice = stock.price.numberValue()

    val recentReports = (0 until minOf(reports.length(), 30)).map { reports.getJSONObject(it) }
    val brokerLatestReports = recentReports
        .filter { it.optString("brokerName").isNotBlank() }
        .groupBy { it.optString("brokerName") }
        .mapNotNull { (_, brokerReports) -> brokerReports.maxByOrNull { it.optString("writeDate") } }
    val reportTexts = brokerLatestReports.map {
        "${it.optString("title")} ${it.optString("previewContent")}"
    }
    val targetPrices = brokerLatestReports.mapNotNull { report ->
        val text = "${report.optString("title")} ${report.optString("previewContent")}"
        val target = extractTargetPrice(text) ?: return@mapNotNull null
        val upside = if (currentPrice > 0) (target - currentPrice) / currentPrice * 100.0 else return@mapNotNull null
        if (upside !in -30.0..150.0) return@mapNotNull null
        val reportDate = runCatching { LocalDate.parse(report.optString("writeDate")) }.getOrNull()
        val ageDays = reportDate?.let { ChronoUnit.DAYS.between(it, LocalDate.now()).coerceAtLeast(0) } ?: 180
        target to (1.0 / (1.0 + ageDays / 30.0))
    }
    val targetUpside = if (currentPrice > 0 && targetPrices.size >= 3) {
        ((weightedMedian(targetPrices) - currentPrice) / currentPrice) * 100.0
    } else {
        null
    }
    val upgrades = reportTexts.count { text ->
        "상향" in text && ("목표주가" in text || "투자의견" in text || "이익 전망" in text)
    }
    val downgrades = reportTexts.count { text ->
        "하향" in text && ("목표주가" in text || "투자의견" in text || "이익 전망" in text)
    }
    val brokerCount = brokerLatestReports.size
    val newsSummary = brokerLatestReports
        .sortedByDescending { it.optString("writeDate") }
        .take(4)
        .mapNotNull { report ->
            val title = report.optString("title").trim()
            if (title.isBlank()) return@mapNotNull null
            val broker = report.optString("brokerName")
            val writeDate = report.optString("writeDate")
            val preview = report.optString("previewContent").trim().let {
                if (it.length > 60) it.take(60) + "…" else it
            }
            "[$writeDate·$broker] $title" + if (preview.isNotBlank()) " — $preview" else ""
        }

    val financeInfo = finance.optJSONObject("financeInfo") ?: JSONObject()
    val periods = financeInfo.optJSONArray("trTitleList") ?: JSONArray()
    val rows = financeInfo.optJSONArray("rowList") ?: JSONArray()
    val actualKeys = (0 until periods.length())
        .map { periods.getJSONObject(it) }
        .filter { it.optString("isConsensus") == "N" }
        .map { it.optString("key") }
    val consensusKey = (0 until periods.length())
        .map { periods.getJSONObject(it) }
        .firstOrNull { it.optString("isConsensus") == "Y" }
        ?.optString("key")
    val latestActualKey = actualKeys.lastOrNull()
    val previousActualKey = actualKeys.dropLast(1).lastOrNull()

    fun metric(title: String, key: String?): Double? {
        if (key == null) return null
        for (index in 0 until rows.length()) {
            val row = rows.getJSONObject(index)
            if (row.optString("title") == title) {
                return row.optJSONObject("columns")
                    ?.optJSONObject(key)
                    ?.optString("value")
                    ?.numberValue()
                    ?.takeUnless { it == 0.0 && row.optJSONObject("columns")?.optJSONObject(key)?.optString("value") == "-" }
            }
        }
        return null
    }

    val actualProfit = metric("영업이익", latestActualKey)
    val previousProfit = metric("영업이익", previousActualKey)
    val expectedProfit = metric("영업이익", consensusKey)
    val actualEps = metric("EPS", latestActualKey)
    val expectedEps = metric("EPS", consensusKey)
    val per = kiwoom.per ?: metric("PER", consensusKey) ?: metric("PER", latestActualKey)
    val pbr = kiwoom.pbr ?: metric("PBR", consensusKey) ?: metric("PBR", latestActualKey)
    val debtRatio = kiwoom.dartDebtRatio ?: metric("부채비율", latestActualKey)
    val verifiedOperatingProfit = kiwoom.dartOperatingProfit ?: actualProfit
    val profitGrowth = growthRate(actualProfit, expectedProfit)
    val epsGrowth = growthRate(actualEps, expectedEps)

    var foreignBuy = 0.0
    var institutionBuy = 0.0
    var totalVolume = 0.0
    val trendDays = minOf(kiwoom.dailyPrices.size, 20)
    var liquidDays = 0
    var totalTradingValue = 0.0
    for (index in 0 until trendDays) {
        foreignBuy += kiwoom.foreignerBuys.getOrNull(index) ?: 0.0
        institutionBuy += kiwoom.institutionBuys.getOrNull(index) ?: 0.0
        val dailyTradingValue = kiwoom.dailyTradingValues.getOrNull(index) ?: 0.0
        totalVolume += dailyTradingValue * 100_000_000.0 / (kiwoom.dailyPrices.getOrNull(index) ?: 1.0)
        totalTradingValue += dailyTradingValue
        if (index < 5 && dailyTradingValue >= 30.0) liquidDays++
    }
    val averageTradingValue = if (trendDays > 0) totalTradingValue / trendDays else 0.0
    val listedLongEnough = actualKeys.size >= 2
    val liquid = averageTradingValue >= 50.0 && liquidDays >= 3 && listedLongEnough
    val flowRatio = if (totalVolume > 0) (foreignBuy + institutionBuy) / totalVolume * 100.0 else 0.0
    val priceTrend = if (trendDays >= 2) {
        val newest = kiwoom.dailyPrices[0]
        val oldest = kiwoom.dailyPrices[trendDays - 1]
        if (oldest > 0) (newest - oldest) / oldest * 100.0 else 0.0
    } else {
        stock.changeRate
    }
    val recentVolatility = kiwoom.dailyPrices
        .zipWithNext()
        .take(10)
        .mapNotNull { (newer, older) ->
            if (older > 0) abs((newer - older) / older * 100.0) else null
        }
        .averageOrZero()
    val stopRate = (recentVolatility * 1.35).coerceIn(2.8, 5.5)
    val targetRate = (targetUpside?.div(3.0) ?: 4.0).coerceIn(2.5, 8.0)
    val targetPrice = if (currentPrice > 0) round(currentPrice * (1 + targetRate / 100.0)) else null
    val stopPrice = if (currentPrice > 0) round(currentPrice * (1 - stopRate / 100.0)) else null

    // 손익비(Reward/Risk) 기반 기대값 점수 산출
    val rewardRiskRatio = targetRate / stopRate
    val expectancyScore = when {
        rewardRiskRatio >= 2.5 -> 10.0
        rewardRiskRatio >= 1.8 -> 7.0
        rewardRiskRatio >= 1.2 -> 4.0
        else -> 0.0
    }

    val earningsScore = (
        12.5 +
            (profitGrowth ?: 0.0).coerceIn(-50.0, 100.0) / 8.0 +
            (epsGrowth ?: 0.0).coerceIn(-50.0, 100.0) / 8.0
        ).coerceIn(0.0, 25.0)
    val targetBiasPenalty = if (targetUpside != null && targetUpside > 40.0 && upgrades == 0) 3.0 else 0.0
    val reportScore = (
        (targetUpside ?: 0.0).coerceIn(-20.0, 80.0) / 8.0 +
            upgrades * 2.0 - downgrades * 3.5 + brokerCount.coerceAtMost(5) -
            targetBiasPenalty
        ).coerceIn(0.0, 16.0)
    val flowScore = (8.0 + flowRatio.coerceIn(-5.0, 5.0) * 1.8).coerceIn(0.0, 20.0)
    val trendScore = when {
        priceTrend > 10.0 -> 15.0
        priceTrend > 0.0 -> 7.5 + priceTrend * 0.75
        priceTrend > -10.0 -> 7.5 + priceTrend * 0.5
        else -> 0.0
    }.coerceIn(0.0, 15.0)
    val financialScore = when {
        verifiedOperatingProfit != null && verifiedOperatingProfit <= 0 -> 0.0
        debtRatio == null -> 5.0
        debtRatio <= 80 -> 10.0
        debtRatio <= 150 -> 7.0
        debtRatio <= 250 -> 3.0
        else -> 0.0
    }
    var riskPenalty = kiwoom.dartRiskPenalty + targetBiasPenalty

    // 낙하 방지 필터 (Falling Knife Guard): 당일 급락 종목 강력 페널티
    if (stock.changeRate <= -4.0) {
        riskPenalty += 15.0 // 당일 4% 이상 하락 시 즉시 하위권으로 밀어냄
    } else if (stock.changeRate <= -7.0) {
        riskPenalty += 30.0 // 7% 이상 폭락 시 사실상 추천 제외
    }

    // 단기 역배열 감지: 현재가가 최근 5일 평균보다 현저히 낮으면 감점
    val shortTermAvg = kiwoom.dailyPrices.take(5).averageOrZero()
    if (shortTermAvg > 0 && currentPrice < shortTermAvg * 0.96) {
        riskPenalty += 8.0
    }

    if (actualProfit != null && previousProfit != null && abs(growthRate(previousProfit, actualProfit) ?: 0.0) > 150) {
        riskPenalty += 4.0
    }

    val reasons = buildList {
        if (stock.changeRate <= -3.0) add("단기 낙폭 과대 주의")
        if (targetUpside != null && targetUpside > 10) add("상승여력 ${targetUpside.toInt()}%")
        if (upgrades > downgrades) add("리포트 전망 상향")
        if ((profitGrowth ?: 0.0) > 15 || (epsGrowth ?: 0.0) > 15) add("이익 전망 개선")
        if (flowRatio > 0) add("외국인·기관 순매수")
        if (liquid) add("유동성 기준 통과")
        add("키움 시세·수급 반영")
        if (kiwoom.dartReasons.isEmpty()) add("DART 위험공시 없음")
        if (kiwoom.dartReasons.isNotEmpty()) add("DART ${kiwoom.dartReasons.first()} 감점")
        if (financialScore <= 3) add("재무 위험 반영")
    }.take(3)
    val details = buildList {
        add(
            if (targetUpside != null) {
                "상승여력 ${formatRate(targetUpside)}: 최근 리포트의 유효 목표가격과 현재가를 비교"
            } else {
                "상승여력: 유효한 목표가격 데이터가 부족하여 점수에 반영하지 않음"
            }
        )
        add(
            "실적 ${earningsScore.toInt()}/25점: 영업이익 전망 ${
                profitGrowth?.let { formatRate(it) } ?: "자료 부족"
            }, EPS 전망 ${epsGrowth?.let { formatRate(it) } ?: "자료 부족"}"
        )
        add(
                "리포트 ${reportScore.toInt()}/20점: 증권사별 최신 ${brokerLatestReports.size}건, " +
                "유효 목표가 ${targetPrices.size}곳, 상향 ${upgrades}건·하향 ${downgrades}건"
        )
        add(
            "수급 ${flowScore.toInt()}/20점·추세 ${trendScore.toInt()}/15점: " +
                "외국인·기관 순매수 비율 ${formatRate(flowRatio)}, 최근 가격 흐름 ${formatRate(priceTrend)}"
        )
        add(
            "재무 ${financialScore.toInt()}/10점: 부채비율 ${
                debtRatio?.let { "%.1f%%".format(it) } ?: "자료 부족"
            }${when {
                riskPenalty > 0 -> ", 위험·급락 페널티 ${riskPenalty.toInt()}점"
                else -> ", 중대 위험공시 감점 없음"
            }}"
        )
    }

    val baseScore = earningsScore + reportScore + flowScore + trendScore + financialScore + expectancyScore - riskPenalty
    // 단기: 수급·추세·손익비 중심 / 장기: 실적·리포트·재무 중심 (장기는 밸류에이션 10점을 fetchStocks에서 가산)
    val shortTermScore = ((flowScore + trendScore + expectancyScore) / 45.0 * 100.0 - riskPenalty).coerceIn(0.0, 100.0)
    val longTermBase = ((earningsScore + reportScore + financialScore) / 51.0 * 90.0 - riskPenalty * 0.5).coerceIn(0.0, 90.0)
    return stock.copy(
        score = baseScore.coerceIn(0.0, 95.0),
        targetUpside = targetUpside,
        targetPrice = targetPrice,
        stopPrice = stopPrice,
        stopRate = stopRate,
        reportCount = brokerLatestReports.size,
        per = per,
        pbr = pbr,
        baseScore = baseScore,
        liquid = liquid,
        reasons = reasons + if (expectancyScore >= 7.0) listOf("손익비 우수") else emptyList(),
        details = details + "기대값 ${expectancyScore.toInt()}/10점: 손익비 ${"%.2f".format(rewardRiskRatio)} (목표 ${formatRate(targetRate)} / 손절 ${formatRate(stopRate)})",
        newsSummary = newsSummary,
        shortTermScore = shortTermScore,
        longTermScore = longTermBase
    )
}

private fun fetchKiwoomSnapshot(code: String): KiwoomSnapshot {
    val json = JSONObject(getJson("$ProxyBaseUrl/stock/$code"))
    fun values(name: String): List<Double> {
        val array = json.optJSONArray(name) ?: return emptyList()
        return (0 until array.length()).map { array.optDouble(it, 0.0) }
    }
    return KiwoomSnapshot(
        per = json.optDouble("per").takeUnless { it.isNaN() || it <= 0 },
        pbr = json.optDouble("pbr").takeUnless { it.isNaN() || it <= 0 },
        dailyPrices = values("dailyPrices"),
        dailyTradingValues = values("dailyTradingValues"),
        foreignerBuys = values("foreignerBuys"),
        institutionBuys = values("institutionBuys"),
        dartAvailable = json.optBoolean("dartAvailable", false),
        dartDebtRatio = json.optDouble("dartDebtRatio").takeUnless { it.isNaN() },
        dartOperatingProfit = json.optDouble("dartOperatingProfit").takeUnless { it.isNaN() },
        dartRiskPenalty = json.optDouble("dartRiskPenalty", 0.0),
        dartReasons = buildList {
            val array = json.optJSONArray("dartReasons") ?: JSONArray()
            for (index in 0 until array.length()) add(array.optString(index))
        }
    )
}

private fun isKiwoomProxyAvailable(): Boolean = runCatching {
    JSONObject(getJson("$ProxyBaseUrl/health")).optBoolean("ok", false)
}.getOrDefault(false)

private fun extractTargetPrice(text: String): Double? {
    val tenThousands = Regex("""목표주가.{0,20}?([\d,.]+)\s*만원""").find(text)
    if (tenThousands != null) return tenThousands.groupValues[1].numberValue() * 10_000.0
    val won = Regex("""목표주가.{0,20}?([\d,]+)\s*원""").find(text)
    return won?.groupValues?.get(1)?.numberValue()
}

private fun weightedMedian(values: List<Pair<Double, Double>>): Double {
    val sorted = values.sortedBy { it.first }
    val halfWeight = sorted.sumOf { it.second } / 2.0
    var accumulated = 0.0
    for ((value, weight) in sorted) {
        accumulated += weight
        if (accumulated >= halfWeight) return value
    }
    return sorted.last().first
}

private fun growthRate(oldValue: Double?, newValue: Double?): Double? {
    if (oldValue == null || newValue == null || oldValue == 0.0) return null
    return (newValue - oldValue) / abs(oldValue) * 100.0
}

private fun relativeValueScore(value: Double?, median: Double?): Double {
    if (value == null || median == null || value <= 0 || median <= 0) return 2.5
    val ratio = (median / value).coerceIn(0.5, 2.0)
    return (ratio / 2.0 * 5.0).coerceIn(0.0, 5.0)
}

private fun List<Double>.median(): Double? {
    if (isEmpty()) return null
    val sorted = sorted()
    val middle = sorted.size / 2
    return if (sorted.size % 2 == 0) (sorted[middle - 1] + sorted[middle]) / 2.0 else sorted[middle]
}

private fun String.numberValue(): Double =
    replace(",", "").replace("+", "").replace("%", "").trim().toDoubleOrNull() ?: 0.0

private fun JSONObject.optNullableDouble(name: String): Double? =
    if (has(name) && !isNull(name)) optDouble(name) else null

private fun getJson(address: String): String {
    var lastException: Exception? = null
    repeat(2) { attempt -> // 최대 2회 재시도 로직 추가 (타임아웃 대응)
        val connection = URL(address).openConnection() as HttpURLConnection
        try {
            val localProxy = address.startsWith(ProxyBaseUrl)
            connection.connectTimeout = if (localProxy) 5_000 else 8_000
            connection.readTimeout = if (localProxy) 90_000 else 8_000
            connection.setRequestProperty("User-Agent", "TopPicks Android")
            return connection.inputStream.bufferedReader().use { it.readText() }
        } catch (e: Exception) {
            lastException = e
            if (attempt == 0) Thread.sleep(500) // 첫 실패 시 잠시 대기 후 재시도
        } finally {
            connection.disconnect()
        }
    }
    throw lastException ?: Exception("Network error")
}

private fun formatRate(rate: Double): String =
    if (rate > 0) "+%.2f%%".format(rate) else "%.2f%%".format(rate)

private fun formatWon(value: Double): String = "%,.0f KRW".format(value)

private fun rateColor(rate: Double): Color = when {
    rate > 0 -> RisingRed
    rate < 0 -> FallingBlue
    else -> MutedText
}

private val KeyboardArrowDown: ImageVector
    get() = ImageVector.Builder(
        name = "ArrowDown",
        defaultWidth = 24.dp,
        defaultHeight = 24.dp,
        viewportWidth = 24f,
        viewportHeight = 24f
    ).path(fill = null, stroke = null) {
        moveTo(7.41f, 8.59f)
        lineTo(12f, 13.17f)
        lineTo(16.59f, 8.59f)
        lineTo(18f, 10f)
        lineTo(12f, 16f)
        lineTo(6f, 10f)
        lineTo(7.41f, 8.59f)
        close()
    }.build()

private val AppBackground = Color(0xFFF5F7FB)
private val CardBackground = Color.White
private val BrandBlue = Color(0xFF365CF5)
private val InfoBackground = Color(0xFFEAF0FF)
private val RankBackground = Color(0xFFE8EDFF)
private val MutedText = Color(0xFF737B8C)
private val RisingRed = Color(0xFFE44755)
private val FallingBlue = Color(0xFF3272D9)
