# 종목별 요인 저장과 갱신 (2026-10-02)

`tools/factor_store.py`는 SQLite `reports/factors.db`에 요인 정의, 종목별 가설,
수치 관측, 출처가 있는 사건을 저장합니다. 새 추천 생성 시 검증된 DART 성장률과
시가총액 대비 20일 수급을 저장하도록 연결했습니다. 과거 스냅숏은 수정하지 않습니다.
값, 단위, 관측·공개·수집 시각을 보존하며 미래 자료·잘못된 단위·비정상 수치는 거부합니다.
과거 시점 조회는 공개 시각과 실제 수집 시각을 모두 확인합니다. 수정 자료는 새 행이며
기존 관측 및 사건은 변경·삭제하지 않습니다.

| 요인 | 갱신 주기 기준 | 현재 연결 범위 |
|---|---|---|
| 영업이익·매출 성장 | 공시 발표 후 / 분기 | 기존 DART 수집 → 새 추천 생성 시 저장 |
| 외국인·기관 20일 수급 / 시가총액 | 일별 데이터 발표 후 | 기존 KRX/키움 수집 → 새 추천 생성 시 저장 |
| 환율 | 제공사 지원 주기, 분·일별 | 입력 구조만 구현, 실시간 환율 API 미연결 |
| HBM 수요·공급·메모리 가격 | 일·주·월 또는 실적 발표 | SK하이닉스 관련 가설 등록, 실제 수치 피드 미연결 |
| 고객사 설비투자 | 분기·발표 시점 | 입력 구조만 구현, 고객사 연결·통화 정규화 필요 |
| 계약·증설·규제·고객사·전망 사건 | 발표 확인 시 | 사건 입력 구조만 구현, 자동 뉴스/IR 수집 미연결 |

HBM 등의 종목별 가설은 사용자 예시에서 등록한 hypothesis-only 상태입니다.
기업별 민감도 회귀·인과 추론 또는 종목 상승 확률이 학습되었다는 뜻이 아닙니다.
현재 데이터베이스는 점수 가중치를 자동 변경하지 않습니다. 다변량 민감도 추정에는
동일 시점의 요인 역사와 수정주가, 시장·업종·환율 통제, 지연 효과, 비중복
학습/평가 구간이 필요합니다. 단순 상관이나 뉴스 문구로 수요 강도를 만들지 않습니다.

실시간 가격과 분기 실적을 같은 빈도로 갱신하지 않습니다. 현재 구현의 자동 수집은
기존 Windows 추천 생성 주기를 따르며 별도 실시간 수집 데몬을 설치하지 않았습니다.
Cloudflare D1에는 추천의 factorCollection 상태만 포함될 수 있으며, SQLite의 전체
요인 이력을 D1로 복제하는 기능은 아직 연결하지 않았습니다.

직접 입력 / 시점 조회 예:

```powershell
.\.venv\Scripts\python.exe tools\factor_store.py --observations reports\factor-input.json --code 000660
.\.venv\Scripts\python.exe tools\factor_store.py --events reports\factor-events.json --code 000660
.\.venv\Scripts\python.exe tools\factor_store.py --code 000660 --as-of 2026-10-02T12:00:00+09:00
```

수치 JSON은 `code,factor,value,unit,observedAt,availableAt,collectedAt,source`를 필요로
합니다. 사건 JSON은 `code,category,publishedAt,collectedAt,source,text`입니다.
타임스탬프에는 시간대를 포함해야 합니다. 공급사 통화·단위가 다르면 입력 전에
명시적으로 정규화해야 합니다. HBM 가격·고객사별 물량은 공개 자료가 제한되므로
관련 데이터 이용권/API가 필요할 수 있습니다. 인증키를 채팅 또는 Git에 저장하지 않습니다.
