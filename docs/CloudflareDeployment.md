# Cloudflare Workers 배포

## 현재 운영 연결: Windows → Worker → D1

`toppick`은 `toppick-data` D1 데이터베이스의 저장 결과를 표시합니다.
Windows 추천 생성 완료 시 `tools/publish_cloudflare.py`가 3종 보고서를 업로드합니다.
Tunnel과 DATA_API_BASE_URL은 D1 연결 후 필요하지 않습니다.
Windows가 꺼져도 마지막 저장 자료는 표시되며, 새 수집에는 Windows 실행이 필요합니다.

로컬 인증 설정은 Git에서 제외된 `key/cloudflare-upload.json`의 `workerUrl`,
`uploadToken`입니다. 대응하는 Worker Secret 이름은 `UPLOAD_TOKEN`입니다.
수동 재업로드: `.\.venv\Scripts\python.exe tools\publish_cloudflare.py`
자동 업로드 상태: `reports/cloudflare-publish-status.json`.

DB는 종류별 최신 JSON과 한국 날짜별 최초 스냅샷을 보관합니다. 기존 로컬 전체 보고서
이력은 그대로 남습니다. 중복 업로드는 저장 이력을 늘리지 않으며 오래된 결과로 최신 결과를
덮어쓰지 않습니다. 관측/분석 시각을 업로드 시각으로 바꾸지 않습니다.
이 단계는 추천 결과 DB 연결이며, 종목별 원시 시세·재무를 정규화한 DB나 Cloudflare 직접 수집은 아닙니다.
신규 환경 DB 설정 시 `npx wrangler d1 migrations apply toppick-data --remote`를 먼저 실행합니다.

아래 Windows API 연결 안내는 D1을 사용하지 않는 구형 중계 방식에 해당합니다.

저장소 루트에서 `npx wrangler deploy`를 실행합니다. Wrangler가 자동으로
`npm run build`를 실행해 Windows 대시보드 HTML을 `dist/index.html`로 추출합니다.
Linux 빌드 서버에는 PowerShell/Python 설치가 필요하지 않습니다.

Cloudflare Git 빌드 설정:
- 루트 디렉터리: 저장소 루트
- 빌드 명령: 비워도 됩니다 (Wrangler가 실행). 필요하면 `npm run build`.
- 배포 명령: `npx wrangler deploy`
- Worker 이름: `toppick` (Cloudflare에서 만든 이름이 다르면 wrangler.jsonc와 맞추기)

## 실제 추천 데이터 연결

Workers는 웹 화면과 읽기 전용 API 중계를 제공합니다. Windows의 PowerShell/Python
수집·분석 엔진은 기존 PC/서버에서 계속 실행해야 합니다. 배포만으로 데이터가 생성되지 않습니다.
연결 전에는 503과 함께 화면에 `데이터 미연결`이 표시됩니다.
로컬 reports, key, 환경 파일은 정적 배포물에 포함되지 않습니다.

1. Windows 수집 서버를 유지하고 Cloudflare Tunnel 등을 통해 HTTPS로 연결합니다.
   localhost 주소는 Worker에서 사용할 수 없습니다.
2. 원본 서버는 Cloudflare Access 서비스 토큰 정책으로 보호하세요.
   외부에 인증 없이 수집 서버 전체를 공개하지 마세요.
3. Worker 설정 → Variables and Secrets에 `DATA_API_BASE_URL`을
   `https://your-protected-data-host.example` 형태로 설정합니다 (경로/쿼리 없음).
4. Access 사용 시 `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`을 **Secret**으로
   등록합니다. 이 값은 브라우저로 전달하지 않습니다.
5. 변경을 배포한 뒤 추천 시각과 종목 목록을 확인합니다.

공개 대시보드에는 원본의 추천/검증/확률 결과가 표시됩니다. 민감한 원본 데이터를
제공하지 마세요. 공개 API에서 계산 요청(`?refresh=1`)과 쓰기 메서드는 차단됩니다.
화면의 `최신 자료 확인`은 저장된 결과를 다시 읽습니다. 새 분석은 Windows에서 실행하세요.
원본 연결 실패 시 기존 목록을 지우고 사용 불가 상태를 표시합니다.

## 로컬 검증

```sh
npm ci
npm test
npx wrangler deploy --dry-run
npm run dev
```

`npm run dev`의 기본 포트가 Windows 프록시(8787)와 겹치면
`npm run dev -- --port 8788`을 사용하세요.
