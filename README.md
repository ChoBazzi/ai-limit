# AI Limit

macOS 14 이상에서 개인 AI 구독과 코딩 도구의 **보고된 사용량**을 보여 주는 Swift 6 메뉴 막대 앱과 WidgetKit 확장입니다. 한국어 UI, 라이트/다크/시스템 테마, **서비스별 여러 계정**, 계정별 연결 동의와 선택적 로컬 토큰 보기를 제공합니다.

**현재 검증 범위:** 9개 공급자의 합성 계약 fixture, 상태/보안/로컬 기록 회귀 테스트, unsigned 앱·확장 빌드, 실제 macOS 메뉴/설정 앱 실행을 검증했습니다. **모든 공급자의 실계정은 미검증**이며 Apple Team 서명을 사용한 실제 App Group 공유·WidgetKit 갤러리 등록은 미검증입니다.

**외부 앱 없는 직접 로그인:** Codex·Claude·Antigravity·Cursor·Copilot·Windsurf·Grok·Kiro의 자체 인증→사용량 조회 경로와 Perplexity의 앱 소유 웹 세션 연결을 구현했습니다. 공급자 CLI/에디터 설치, 다른 앱의 로그인 파일, 사용자의 GitHub App 등록이 필요하지 않습니다. 공개 네이티브 클라이언트와 내부 API를 사용하는 **비공식 연동**이며, 구현 존재·업체 정책·실계정 성공은 별개입니다. 모든 실계정은 미검증입니다.

## 빌드와 실행

외부 Swift package나 프로젝트 생성기는 필요하지 않습니다. `AILimit.xcodeproj`의 공유 scheme은 `AILimit`이며 local package를 참조합니다.

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project AILimit.xcodeproj -scheme AILimit \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build

open .build/xcode/Build/Products/Debug/AILimit.app
```

Dock 아이콘 대신 메뉴 막대의 **반짝임 아이콘** 또는 고정 계정 이름을 클릭하세요. 오른쪽 위 격자 아이콘(**사용량 대시보드**)으로 전체 화면을 열고, 계정 카드를 누르면 해당 계정 관리로 이동합니다. 연결이 없으면 **서비스 연결**로 시작합니다. `ailimit://settings`는 대시보드, `ailimit://provider/codex`는 서비스 관리, `ailimit://account/<로컬 연결 ID>`는 정확한 계정을 엽니다. 앱을 종료하면 백그라운드 수집도 종료됩니다.

### 사용량 중심 대시보드

- 첫 화면은 계정별 **5시간 한도·주간 한도·로컬 토큰·리셋·연결 상태** 카드입니다. 모든 화면의 기본 수치와 막대를 **남은 비율**로 통일했습니다. `80% 남음`이면 막대도 80%입니다. Codex는 응답의 실제 기간을 시간·주 단위로 표시하고, 기간이 없으면 5시간/주간으로 추정하지 않습니다.
- 메뉴 패널과 대시보드 상단에 **이번 주 / 이번 달 토큰 총량·API 환산액(USD)**을 표시합니다. Mac 시간대로 월요일·매월 1일부터 현재까지, 읽기에 동의한 로컬 기록만 합산합니다. 같은 폴더를 여러 계정에 연결하거나 OMP 세션을 복사·분기해도 요청을 중복 합산하지 않습니다. 계정 한도 합계나 실제 청구액은 아닙니다.
- **집계 기준**에서 단가 기준일·갱신 시각·미산정 요청 수를 확인합니다. 미지원 모델도 알려진 토큰 총량에는 포함하며, 표시 금액은 단가와 과금 항목이 확인된 요청의 소계입니다. 기록 없음·미연결·명시적 0을 구분하고, 읽기 누락은 `일부 기록`, 단가 누락은 `금액 일부`로 표시합니다.
- 주·월 집계는 OMP의 Codex/Claude 요청 기록과 Claude 기본 로그를 지원합니다. **Codex 기본 로그의 누적·상속 카운터는 주·월 합계에서 제외**하며 OMP 기록 연결을 안내합니다. 기존 최근 세션 카운터는 유지합니다. 주·월 모아보기는 메뉴 패널·대시보드 기능이며 WidgetKit의 1/4/8개 계정 배치는 변경하지 않았습니다.
- 환산은 **2026-10-12 기준 표준·글로벌 API 토큰 단가**로 과거 로컬 기록까지 다시 계산한 비교용 추정액입니다. 실제 과거 요금·구독 결제액·도구 추가요금·세금·할인·Fast/Batch/지역 가산을 재현하지 않습니다. Claude 캐시 TTL이 없으면 기본 5분 쓰기 단가를 가정하고, 1시간 부분이 기록된 경우 이를 구분합니다. 지원 모델 ID와 요청별 긴 문맥 단가는 `APIPriceCatalog.swift`에 명시되어 있습니다. 출처: [OpenAI](https://developers.openai.com/api/docs/pricing), [Claude](https://platform.claude.com/docs/en/about-claude/pricing).
- 정상은 청록, 한도 임박은 주황, 소진·초과는 빨강이며 경고 문구를 함께 표시합니다. 알 수 없는 값과 무제한에는 가짜 0%/100% 막대를 만들지 않습니다. 상세에서는 원본 사용률과 초과분도 확인할 수 있습니다.
- 토큰은 구독 한도와 구분선으로 분리하되 접지 않고 표시합니다. **이 Mac 최근 세션** 또는 **오늘/최근 7일 로컬 기록**의 실제 관찰값이며, 한도 퍼센트를 토큰 수로 변환하지 않고 없는 total을 입력·출력 합계로 만들지 않습니다. 계정 관리 → **로컬 기록 · 별도 읽기 동의**에서 폴더를 연결해야 합니다. 현재 원격 계정의 전체 사용량과 동일하다고 가정하지 않습니다.
- 리셋은 **`2시간 15분 후 리셋 (15:30)`**처럼 상대 시간과 실제 시각을 함께 표시합니다. 시각은 Mac의 현지 시간대·24시간제로 표시하고, 다른 날이면 월·일도 붙입니다. 작은 위젯은 괄호 속 시각을 다음 줄에 표시합니다. 시각이 없으면 날짜와 `시각 미제공`, 이미 지났으면 `리셋 지남 · 갱신 필요`로 표시하며 정확한 전체 날짜는 상세·툴팁에 유지합니다.
- **Codex 리셋권:** 메뉴 카드와 위젯에는 남은 개수, 클릭한 상세에는 각 리셋권의 사용기한을 표시합니다. 한도 리셋 시각·크레딧 잔액과는 별개입니다. 직접 로그인과 CLI 연결을 지원하며, 서버가 정보를 주지 않으면 `정보 미제공`/`—`로 표시하고 0개로 추정하지 않습니다. 상세가 일부만 제공되면 나머지 개수의 기한 미제공을 안내합니다. 기한이 지난 캐시는 이전 관찰값으로 표시하며 임의 차감하지 않습니다. **조회 전용**으로 리셋권을 사용하거나 구매하지 않습니다.
- 헤더는 인디고 게이지 아이콘을 사용합니다. 위젯 계정명·수치와 앱 리셋 글씨를 조금 키우고 내부 여백을 조정했습니다. 작은 위젯은 중복 헤더 대신 계정명을 게이지 옆에 표시합니다.
- 메뉴 패널은 **740pt 너비의 2열**, 카드 폭은 356pt입니다. 카드 내부 여백을 늘렸으며, 5시간·주간 두 한도와 리셋권을 가진 계정 기준으로 스크롤 없이 **6개 카드**를 확인했습니다. 대시보드는 카드 여백을 늘리고 기본 창의 3열을 유지합니다.
- 상단 숫자는 등록된 계정 수, 마지막 성공 관찰값이 있는 계정 수, 연결 확인이 필요한 계정 수입니다. 계정 한도를 합산하거나 수집하지 않은 추세를 만들지 않습니다.
- 계정 카드 → **계정 관리**에서는 상세 사용량을 먼저 보여 줍니다. 기존 계정의 **로그인 관리 · 재연결**, **로컬 기록 · 별도 읽기 동의**는 필요할 때 펼칩니다. 새 계정의 로그인 안내는 자동으로 열리며 서비스별 제약과 동의 절차를 유지합니다.
- 새로고침 실패·재로그인 필요 시 이전 관찰값을 회색으로 표시하고 사유를 함께 보여 줍니다. 15분이 지났거나 리셋 시간이 지나면 **갱신 필요**를 표시하며, 수치를 임의로 초기화하지 않습니다. 날짜만 제공된 리셋에는 정확한 시각을 붙이지 않습니다.
- 왼쪽 아래 **화면 모드**에서 시스템·라이트·다크를 선택합니다. 위젯도 기간별 남은 한도와 로컬 토큰을 함께 표시하며, 표시되지 않은 계정 수는 헤더의 `+N`으로 표시합니다.

### 실제 위젯을 사용하기 위한 서명

1. Xcode Settings → Accounts에서 본인의 Apple 개발 계정을 준비하세요.
2. 앱과 `AILimitWidgets` target에 **동일한 실제 Development Team**을 지정하세요.
3. 두 entitlement와 Info.plist의 App Group은 `$(DEVELOPMENT_TEAM).dev.bazzi.ai-limit.shared`입니다. 해당 팀의 macOS App Group 권한과 provisioning/signing 설정을 두 target에 일치시키세요.
4. 서명 빌드에서는 `CODE_SIGNING_ALLOWED=NO`를 제거하고 `DEVELOPMENT_TEAM=<실제 Team ID>`를 전달하세요. 전역 `xcode-select`는 변경할 필요가 없습니다.
5. containing app을 한 번 실행한 뒤 macOS 데스크톱의 **위젯 편집**에서 AI Limit을 추가하세요.

앱은 외부 CLI 실행을 위해 sandbox를 사용하지 않습니다. 확장만 sandbox를 사용하며 Shared 모듈만 링크합니다. App Store 배포용 구성이 아닙니다. 직접 외부 배포에는 별도의 적합한 Apple 배포 서명/공증 절차가 필요합니다. 로컬 자체 서명 인증서는 Apple Team의 App Group 접근 검증을 대신하지 않습니다.

App Group을 사용할 수 없으면 앱은 자기 Application Support에 snapshot을 저장하고 **위젯 공유 설정 필요**를 표시합니다. 확장은 이 fallback 경로를 탐색하지 않습니다.

## 연결 가능한 서비스

| 서비스 | 연결 방식 | 표시하는 관찰값 |
|---|---|---|
| Codex 계정 한도 | 브라우저 OAuth PKCE | 한도별 사용률·리셋·플랜·제공된 크레딧 |
| Claude | 브라우저 OAuth PKCE, **정책 제한 주의** | 5시간·주간·모델별 한도·리셋 |
| Antigravity | Google OAuth PKCE | 실제 quota summary의 그룹/버킷 잔여율·리셋 |
| Cursor | 브라우저 PKCE 승인 + token polling | 현재 청구 기간 포함 사용량·USD 한도·pool 사용률 |
| GitHub Copilot | Device OAuth, 개발자 앱 등록 불필요 | 내부 quota API의 플랜·잔여 한도·제공된 크레딧·리셋 |
| Windsurf | Devin 브라우저 PKCE, 계정 호환성 조건부 | Codeium seat의 일간·주간 잔여율·리셋·플랜 |
| Perplexity | 앱 전용 임시 WKWebView 웹 세션, **OAuth 아님** | 크레딧 금액 잔액·당기 사용·구매·grant·갱신일 |
| Grok | xAI Device OAuth | Build/통합 크레딧 사용률·기간·제공된 추가 사용 USD 금액 |
| Kiro | AWS Builder ID Device Flow | 실제 월간·무료 체험·보너스 크레딧·리셋 |

**ChatGPT 일반 채팅과 Gemini 웹앱의 자동 연결은 이 앱의 9개 공급자 범위에 포함되지 않습니다.** 서비스 열기만 제공합니다. Gemini 웹 quota RPC 구현은 공개 소스에서 발견됐지만 자체 웹 로그인 연결은 별도 검증이 필요합니다. Codex 숫자를 ChatGPT 채팅 한도로, Antigravity 숫자를 Gemini 웹앱 한도로 표시하지 않습니다.

### 여러 계정 연결

1. 대시보드의 **계정 추가**에서 서비스를 선택합니다. 또는 왼쪽 **계정 관리**에서 Codex 등을 선택한 뒤 **계정 추가**를 누릅니다.
2. `개인`, `업무`처럼 구분할 **계정 이름**을 입력하고 로그인 동의 후 로그인합니다. 새 계정은 실제 quota 확인에 성공한 뒤 저장됩니다.
3. 기존 연결은 유지됩니다. 계정 관리의 **계정** 선택기로 전환하고, 저장된 이름은 **이름 저장**으로 변경합니다.
4. **새로고침·재로그인·계정 삭제·메뉴 막대 고정**은 선택한 계정에만 적용됩니다. 메뉴에는 같은 공급자의 계정도 별도 카드로 표시하고, 위젯 편집에서도 계정을 개별 선택합니다.

Codex 브라우저가 기존 OpenAI 계정으로 자동 로그인한다면 브라우저에서 OpenAI 로그아웃 후 추가할 계정으로 다시 로그인하세요. 이미 저장한 AI Limit 연결은 유지됩니다. 확인되지 않은 계정 선택용 OAuth 파라미터나 다른 앱의 인증 저장소를 사용하지 않습니다.

Codex는 알려진 workspace ID와 subject가 모두 같거나 같은 토큰인 중복 연결을 거절합니다. 같은 조직의 다른 구성원은 workspace ID만 같다는 이유로 거절하지 않습니다. 기존 계정 재로그인에서 알려진 workspace/subject가 바뀌면 기존 연결을 유지하고 새 계정 추가를 안내합니다. 신원 필드가 없는 계정을 임의로 동일인으로 판단하지 않으며, 계정 이름은 사용자가 정한 표시용 이름입니다.

이전 단일 연결은 **기본 계정**으로 유지됩니다. 기존 Keychain 키·snapshot ID·메뉴 고정·위젯 선택을 보존하며, 마이그레이션 때문에 토큰을 읽거나 복사하지 않습니다. 새 계정에는 별도 UUID를 부여합니다. 삭제된 위젯 계정은 다른 계정으로 자동 대체되지 않습니다.

CLI 모드는 선택한 도구의 현재 로그인 저장소를 사용합니다. 서로 다른 Codex CLI 계정을 표시하려면 각 계정에 **서로 다른 CODEX_HOME**을 직접 지정하세요. 같은 저장소를 두 번 선택해도 별도 원격 계정으로 바뀌지 않습니다. 직접 OAuth 연결은 CLI 저장소가 필요하지 않습니다.


### CLI 연결

기존에 설치·로그인한 도구가 있는 사용자를 위한 **선택적 읽기 전용 연결**입니다. 설정에서 `고급: 기존 CLI / 수동 세션 연결`을 켜면 입력이 보입니다. 기본 직접 로그인은 이 도구를 사용하지 않습니다. 기존 CLI/수동 연결을 자동 변환하거나 토큰을 추출하지 않으며, 사용자가 새 로그인·quota 검증을 완료하면 교체합니다.

- Codex 조회: `-s read-only -a never app-server`; initialize → initialized → account/read → account/rateLimits/read. API-key 계정은 개인 구독 조회로 인정하지 않습니다. 별도 `CODEX_HOME`은 직접 선택했을 때만 조회에 전달합니다. `account/login/start`는 더 이상 호출하지 않습니다.
- Antigravity: `--version`과 `-p /usage --output-format json`만 실행합니다.
- Copilot 기존 모드: 사용자가 이미 로그인한 `gh`를 선택하면 `gh api --include`로만 조회합니다. 자체 OAuth 모드는 `gh`를 사용하지 않으며 기존 토큰을 추출하지도 않습니다.
- Kiro: `chat --no-interactive /usage`; 일반 pipes만 사용하며 PTY나 credential DB를 읽지 않습니다.

선택한 실행 파일이 없어지면 다시 선택해야 합니다. 다른 실행 파일로 몰래 대체하지 않습니다. 계정 이름이 응답에 없으면 **선택한 CLI 로그인 계정**으로만 표시합니다.

### 직접 로그인 절차

1. 계정 관리에서 **로그인하여 연결** 또는 **로그인 관리 · 재연결**을 펼치고 해당 정책·계정·권한 제약을 읽습니다.
2. 비공식 연동 동의 후 **서비스 이름 + 로그인**을 누릅니다. GitHub App 등록은 필요하지 않습니다. Antigravity는 아래 로컬 OAuth 설정이 먼저 필요합니다.
3. 브라우저 PKCE는 열린 공급자 로그인 화면을 사용합니다. Copilot·Grok·Kiro는 이 창에서 요청한 기기 코드만 승인하세요. 네이티브 클라이언트 ID를 사용하므로 승인 화면의 앱 이름은 AI Limit와 다를 수 있고, 승인 권한은 사용량 읽기보다 넓을 수 있습니다.
4. Perplexity는 앱이 소유한 **임시 웹 창**에서 로그인합니다. Google/Apple의 내장 브라우저 제한이나 기업 SSO/Cloudflare로 거부될 수 있습니다. 외부 브라우저 쿠키를 가져오는 대체 경로를 자동 실행하지 않습니다.
5. 로그인 후 **실제 quota 조회까지 성공해야** 선택한 연결을 저장합니다. 기존 계정과 다른 계정은 그때까지 유지합니다. 로그인 취소·로그인 영역 접기·대시보드 복귀·설정 창 닫기·서비스/계정 전환·앱 정상 종료는 진행 중 인증을 취소하며, 이미 시작한 저장 transaction은 마칩니다.
6. **계정 삭제**는 해당 계정의 앱 Keychain·설정·snapshot 삭제입니다. 다른 계정은 유지합니다. 공급자에서 승인한 권한은 해당 서비스의 계정 설정에서 별도로 철회하세요.

이전 **등록형 GitHub App + 개인 billing API** 경로는 제거했습니다. 해당 연결을 사용했다면 Copilot 화면에서 다시 로그인하세요. 기존 토큰을 다른 클라이언트 토큰으로 재해석하지 않습니다. 새 연결은 `/copilot_internal/user`의 quota이며, 이전 월간 총 사용/할인/순 청구 보고서와 섞지 않습니다.

### Antigravity 로컬 OAuth 설정

Google OAuth 클라이언트 값은 소스와 앱 번들에 포함하지 않습니다. Antigravity 직접 로그인·토큰 갱신은 다음 파일에서 읽습니다. 다른 서비스와 Antigravity의 고급 CLI 연결에는 이 설정이 필요하지 않습니다.

`~/Library/Application Support/AI Limit/antigravity-oauth.json`

사용 권한이 있는 OAuth 클라이언트의 값으로 아래 예시를 채우세요. 예시 문자열 자체는 로그인에 사용할 수 없습니다.

```json
{
  "clientID": "YOUR_GOOGLE_OAUTH_CLIENT_ID",
  "clientSecret": "YOUR_GOOGLE_OAUTH_CLIENT_SECRET"
}
```

```sh
chmod 600 "$HOME/Library/Application Support/AI Limit/antigravity-oauth.json"
```

파일이 없거나 필수 값이 비어 있으면 브라우저·토큰 요청 전에 설정 오류를 표시합니다. redirect URI는 `http://127.0.0.1:51121/oauth2callback`입니다. 사용자 access/refresh 토큰은 이 파일에 넣지 않으며 기존처럼 Keychain에 저장됩니다. 클라이언트를 변경했다면 해당 Google 계정을 다시 연결하세요.

이 파일은 저장소 밖에 보관하고 공유하지 마세요. 저장소 루트로 복사한 같은 이름의 파일도 `.gitignore`에서 제외합니다. 자체 Google OAuth 클라이언트 등록만으로 Antigravity 사용량 API 접근이 보장되지는 않으며, 제3자 클라이언트 재사용과 서비스 정책의 제약은 별개입니다.

### 인증 수명과 보안 경계

- PKCE S256, 암호학적 난수 state/verifier, loopback의 정확한 host/port/path/state와 단일 code를 검증합니다. listener는 **127.0.0.1**에만 bind하며 제한 시간·취소·잘못된 callback·점유된 포트를 처리합니다. 브라우저를 열기 전에 listener가 준비됩니다.
- callback: Codex `http://localhost:1455/auth/callback`, Claude `http://localhost:53692/callback`, Antigravity `http://127.0.0.1:51121/oauth2callback`, Windsurf `http://127.0.0.1:57891/callback`. Cursor는 callback listener 대신 공급자의 승인 polling을 사용합니다.
- Device Flow는 서버 lifetime 내에서 pending/slow_down을 처리하며 무기한 기다리지 않습니다. 기기 코드와 callback code는 설정·snapshot에 저장하지 않습니다.
- access/refresh 토큰·반환된 만료·계정/project/클라이언트 등록 정보는 앱 전용 Keychain 레코드에만 보관합니다. provider binding을 검증하고, 알려진 만료 120초 전부터 갱신합니다. 회전된 refresh는 quota 조회 전에 저장해 quota 실패로 잃지 않습니다.
- refresh가 없는 웹/Devin 세션은 실제 알려진 만료에서 재로그인합니다. 알 수 없는 수명을 임의 30일·영구 토큰으로 만들지 않습니다. Copilot의 실제 비만료 토큰은 허용합니다.
- Perplexity는 nonpersistent WKWebsiteDataStore만 사용합니다. 허용된 Secure/HttpOnly session cookie와 연속 chunk를 선별하고 `/api/auth/session`으로 검증합니다. 성공·취소·실패 후 해당 임시 창의 데이터만 정리합니다.
- 계정별 single-flight, 작업 취소 후 drain, generation 검증이 연결 교체/삭제 뒤 늦은 quota 응답의 복구를 막습니다. 새 연결 검증 중 token 회전은 해당 계정의 메모리에 격리되어 기존 연결이나 다른 계정을 덮어쓰지 않습니다.

### 구현 근거와 서비스별 제한

2026-09-28 공개 소스 조사, 2026-09-29 구현 검증 기준입니다. 아래는 **기술 구현 근거**이지 공급자 승인이나 실계정 성공 보증이 아닙니다. 사용자의 token/secret을 공개 클라이언트 식별자와 혼동하지 않습니다.

| 서비스 | 인증·조회 구현 근거 | 제한 |
|---|---|---|
| Codex | [OpenCode PKCE](https://github.com/anomalyco/opencode/blob/7945de208964a49300d7f770d1a71d078db9a4c4/packages/opencode/src/plugin/openai/codex.ts), [wham usage](https://github.com/steipete/CodexBar/blob/22fbf3559024c9106e3f59847f86e490cafce87b/Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthUsageFetcher.swift) | 개인 Codex 구독, ChatGPT 일반 채팅과 별개 |
| Claude | [pi-mono PKCE](https://github.com/badlogic/pi-mono/blob/11894012dd461232eb075bc890538b6866860a10/packages/ai/src/auth/oauth/anthropic.ts), [직접 usage 구현](https://github.com/flukelaster/LLM-Usage-Widget/tree/4e9ba459dff930af19d325dab4443892c4f2ce9b/Sources/UsageWidget/Providers/Claude) | [Anthropic 정책](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use)은 타사 Claude.ai 로그인 제공을 명시적으로 제한. 구현됐다는 사실이 허가를 뜻하지 않음 |
| Antigravity | [Quotio 자체 인증](https://github.com/nguyenphutrong/quotio/blob/e0ad2858e8cf25240f7736c955491004288dc12c/Packages/QuotioCore/Sources/QuotioInfrastructure/Accounts/MonitorOAuthAuthorizer.swift), [quota summary](https://github.com/nguyenphutrong/quotio/blob/e0ad2858e8cf25240f7736c955491004288dc12c/Packages/QuotioCore/Sources/QuotioInfrastructure/Quota/AntigravityQuotaFetcher.swift) | cloud-platform 포함 권한, 계정 접근 제한·제재 위험. 로그인 성공이나 모델 catalog만으로 quota 성공 처리하지 않음 |
| Copilot | [Device Flow](https://github.com/steipete/CodexBar/blob/22fbf3559024c9106e3f59847f86e490cafce87b/Sources/CodexBarCore/Providers/Copilot/CopilotDeviceFlow.swift), [internal quota](https://github.com/steipete/CodexBar/blob/22fbf3559024c9106e3f59847f86e490cafce87b/Sources/CodexBarCore/Providers/Copilot/CopilotUsageFetcher.swift) | 공개 클라이언트 재사용·내부 endpoint, 플랜별 반환 필드 차이 |
| Kiro | Quotio의 위 자체 인증, [현재 management client](https://github.com/hj01857655/kiro-account-manager/blob/4c3a8d959514c27d1d092b22cd9a4695fb812dee/src-tauri/src/clients/kiro_client.rs) | Builder ID / us-east-1 경로. 소셜 전용·기업 IdC 계정 지원으로 확대하지 않음. 실제 받은 profile ARN만 사용 |
| Cursor | [pi-cursor PKCE](https://github.com/Rahularya01/pi-cursor/blob/7a2ab5e43911b173320bfe06b6ea0cd0ad7a6f76/src/auth/oauth.ts), [동일 토큰 quota](https://github.com/Rahularya01/pi-cursor/blob/7a2ab5e43911b173320bfe06b6ea0cd0ad7a6f76/src/usage.ts) | 표준 Device Flow로 부르지 않음. 미제공 플랜/사용률을 Pro/0%로 추정하지 않음 |
| Grok | [xAI 공식 인증](https://github.com/xai-org/grok-build/tree/f0e3be1100ef5252488e3be8bb0e91cf68d8c305/crates/codegen/xai-grok-login/src), [동일 토큰 billing·USD cents](https://github.com/xai-org/grok-build/blob/f0e3be1100ef5252488e3be8bb0e91cf68d8c305/crates/codegen/xai-grok-shell/src/extensions/billing.rs) | Build/통합 크레딧이며 모든 Grok 웹 메시지 제한은 아님. 공식 client의 권한은 read-only가 아님 |
| Windsurf | [Devin PKCE](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/sdk/auth/devin.go), [동일 session→seat quota](https://github.com/router-for-me/CLIProxyAPI/blob/acdace936fa7df2905500c7f5e0a97d683138dea/internal/auth/devin/record.go) | 모든 기존 Windsurf 계정 호환성 미확인. 조직/이전 상태에 따라 거부될 수 있음. Devin 클라우드 작업 잔액 아님 |
| Perplexity | [자체 웹 로그인과 session](https://github.com/can1357/oh-my-pi/blob/cbe9bc206d07c4395ff465623e229d279d0dd437/packages/ai/src/registry/oauth/perplexity.ts), [credit consumer](https://github.com/steipete/CodexBar/blob/22fbf3559024c9106e3f59847f86e490cafce87b/Sources/CodexBarCore/Resources/Plugins/perplexity.js) | 두 경로를 앱에 연결했으나 실계정 미검증. 내장 브라우저 SSO·Cloudflare·별도 HTTP session 제약. credit ≠ Pro 검색 횟수 |

Gemini 웹에는 [쿠키 기반 quota RPC](https://github.com/HanaokaYuzu/Gemini-API/blob/8c5b1dcbf54ecf093551cc20bd25cef438190ba8/src/gemini_webapi/client.py#L824-L911)가 있으므로 “기술적으로 자동 조회 불가능”이라고 단정하지 않습니다. 현재 앱의 지원 범위에는 추가하지 않았습니다. [개인용 Gemini CLI/Code Assist 종료](https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals)는 Gemini 웹의 종료나 기업용 계정의 일괄 종료와 다릅니다.

### 고급 수동 웹 세션 연결

직접 로그인과 별도로 고급 연결을 선택한 경우에만 사용하는 절차입니다. 서비스 링크에서 로그인한 뒤 개발자 도구 **Network**에서 본인의 사용량 요청 **Cookie header**를 직접 복사하세요. 외부 사이트나 채팅에 비밀을 보내지 마세요. 다른 앱/브라우저의 저장소를 앱이 자동 탐색하지 않습니다.

- Claude: 수동 `sessionKey`는 OAuth 토큰과 다른 인증입니다. 이 필드에는 API 키/Claude Code OAuth를 받지 않고, 여러 조직을 임의 선택하지 않습니다. 이 경로도 Anthropic의 타사 세션 중개 허가를 의미하지 않습니다.
- Cursor: 본인 usage-summary 요청의 Cookie header를 입력합니다.
- Perplexity: 허용된 authjs/next-auth session family의 Cookie를 입력합니다. `.0`, `.1` 등 조각은 0부터 빠짐없이 포함해야 합니다. 여러 family 중 첫 완전한 family만 전송합니다.
- Windsurf: 본인의 Application/Storage에서 `devin_session_token`, `devin_auth1_token`, `devin_account_id`, `devin_primary_org_id`를 직접 복사해 **정확히 이 네 필드**의 JSON을 입력합니다. 여러 줄 입력은 **입력 내용 보기**를 켜서 사용할 수 있습니다.
- Grok: 본인의 `grok login`이 생성한 `~/.grok/auth.json`에서 `https://auth.x.ai::<client-id>` 항목의 **key bearer 값만** 직접 가져옵니다. 파일 전체·refresh_token·`xai-` API 키·Cookie는 입력하지 마세요. 앱은 이 파일을 읽거나 갱신하지 않습니다.

세션은 읽기보다 넓은 계정 권한을 가질 수 있습니다. 만료되면 사용자가 새 값을 입력해야 합니다. 연결 테스트가 실패하면 기존 연결과 Keychain 값은 교체하지 않습니다. 서비스 변경/접속 제한 시 해당 계정만 실패 상태가 됩니다. Grok가 기간만 제공하면 사용률을 만들어 내지 않고 서비스 확인/재연결 안내를 표시합니다.

## 숫자의 의미

- 없는 값과 `0`을 구별합니다. 알려진 used/positive limit 또는 명시된 percent만으로 비율을 계산합니다.
- 표시용 잔여율과 bar는 0–100 범위로 제한하며 원본 관찰값은 바꾸지 않습니다. 110% 사용이면 요약은 `0% 남음 · 한도 초과`, 상세는 `110% 사용 · 10%p 초과`도 표시합니다.
- 잔액만 있고 한도가 없으면 bar를 만들지 않습니다. 무제한은 응답이 명시한 경우에만 표시합니다.
- Claude/Cursor의 확인된 cents 금액은 100:1로 환산합니다. 통화가 없는 Claude 금액은 표시하지 않습니다.
- Perplexity는 cents 기반 **크레딧 금액**을 100:1로 환산합니다. USD나 토큰으로 추정하지 않고, grant별 소진 순서/사용률도 만들지 않습니다.
- Grok onDemand/prepaid 값은 공식 동일 REST decoder의 `Cent = USD cents` 근거에 따라 100:1로 USD 환산합니다. 포함 크레딧 사용률과 분리하며 period-only 응답은 사용량 미제공입니다.
- Copilot premium/chat `credits_used`는 같은 pool일 수 있으므로 더하지 않습니다. placeholder 0/0이나 누락 quota를 무제한/100% 잔여로 바꾸지 않고, 반환된 단위와 플랜별 필드만 표시합니다.
- 서로 다른 공급자·계정의 한도를 합산하거나 평균내지 않습니다. 메뉴 pin은 선택한 **한 계정**과 가장 제한적인 알려진 **기간 이름·남은 비율**을 표시합니다. 오래됨·조회 실패·리셋 경과 시 `이전 관찰`을 붙입니다.

### 선택적 로컬 토큰

웹/CLI quota와 **별개로, 계정마다** 폴더 읽기 동의를 받습니다. 웹 계정 연결 없이도 사용할 수 있고, 웹 계정과 로그 계정이 같다고 가정하지 않습니다. 새 계정에는 다른 계정의 폴더·동의를 복사하지 않습니다. 파일 캐시와 실패 시 이전 관찰은 계정·공급자·폴더·기록 종류별로 격리합니다. 새 종류/폴더를 선택하면 기존 로컬 기록 연결을 교체합니다.

- Codex: `~/.codex`를 선택하면 `sessions`, `archived_sessions`만 읽습니다. 전체 파일에서 가장 최근의 유효 세션 누적 token_count **하나**를 표시합니다. 100→150은 250이 아니라 150입니다. 상속 문맥이 포함될 수 있고 계정/오늘/주간 총량으로 합산하지 않습니다. total은 제공된 total_tokens만 사용합니다.
- Claude: `~/.claude/projects`를 선택합니다. request/message ID로 중복을 제거하고 최종 complete cumulative record를 사용합니다. 사용자 Calendar/timezone의 오늘/최근 7 civil days를 집계합니다. cache read/write/input/output은 별개이며 모두 제공되고 overflow가 없을 때만 total을 계산합니다.
- **OMP**: Codex 또는 Claude 계정 관리 → **로컬 기록 · 별도 읽기 동의** → **OMP 세션 폴더 선택 및 읽기 동의**에서 `~/.omp/agent/sessions`를 선택합니다. Codex 카드에서는 `openai-codex`, Claude 카드에서는 `anthropic` 요청만 읽습니다. 최근 세션 토큰은 카드·위젯에 바로 표시하고, **이 Mac의 로컬 토큰**을 펼치면 오늘·최근 7일과 입력/출력/캐시 세부 항목을 확인할 수 있습니다.
- OMP는 요청별 usage를 집계합니다. 제공된 `totalTokens`를 우선하고, 없으면 입력·출력·캐시 읽기·캐시 쓰기가 모두 있을 때만 overflow 없이 더합니다. OMP의 입력과 캐시 항목은 분리된 값이며, 추론은 출력의 세부 항목이므로 다시 더하지 않습니다. 파일 복사와 분기에서 보존된 항목의 중복을 제거하고 충돌·불명확한 상속·미완성 기록은 partial로 표시합니다. 최근 세션에는 상속된 기록이 포함될 수 있습니다.
- OMP 수치는 **이 Mac의 해당 공급자 기록**입니다. 여러 계정이 같은 OMP 기록 폴더를 사용해도 현재 로그인한 특정 계정의 총량으로 간주하지 않습니다. 기록 종류를 바꾸면 이전 종류의 토큰을 재사용하지 않습니다.
- 프롬프트/응답 본문은 저장·출력하지 않습니다. JSONL을 스트리밍으로 읽고 timestamp/ID/usage만 메모이즈합니다. scan당 5초, 128 MiB, 2,000파일, record당 8 MiB 제한입니다. newline이 없는 진행 중 record는 보류합니다.
- 오류/예산 초과 시 partial로 표시하고 이전 완전한 결과가 있으면 유지합니다. 빈 폴더/삭제된 기록은 사용량 0의 증거가 아닙니다. quota와 token 관찰 시각은 독립적입니다.
- 이전 버전이 저장한 Codex `기본한도 - 18000초` / `추가 기간 한도 · 604800초` 제목도 snapshot을 읽을 때 5시간/주간 표시로 정리합니다. 사용량·리셋·원래 관찰 시각은 바꾸지 않습니다. 앱 실행 중 빌드만 갱신했다면 앱을 재시작해야 새 표시 코드가 적용됩니다.

## 갱신과 위젯

앱은 시작·깨우기·수동 요청을 같은 coordinator 경로로 처리하고, 조회 완료 후 60초 간격으로 다시 조회합니다. 메뉴 열기·앱 창 활성화·위젯 링크로 앱 진입 시에는 최근 성공이 60초 이내여도 즉시 조회를 요청합니다. **계정별 single-flight**로 진행 중인 요청은 공유하며 전체 최대 3개 동시 수집을 유지합니다. 429는 해당 계정의 Retry-After를 존중하고 없거나 0이면 5분 유예합니다. 실패해도 마지막 성공 값과 원시각은 남깁니다. 한 계정의 교체/삭제는 그 계정의 작업만 취소하고 늦은 응답을 버립니다.

위젯은 App Group snapshot만 읽습니다. 네트워크·Keychain·CLI 접근 코드가 없습니다. small/medium/large는 각각 첫 **1/4/8개 계정**을 표시하며 중간·큰 크기는 2열입니다. 나머지는 헤더의 `+N`으로 표시합니다. 계정마다 최대 두 한도와 로컬 토큰 요약을 보여 주며, 알려진 가장 제한적인 한도가 뒤에 있어도 요약에 포함합니다. 작은 위젯은 각 기간의 리셋을, 중간·큰 위젯은 가장 제한적인 한도의 **이름과 해당 리셋**을 표시합니다. 전체 한도·리셋·토큰 세부 항목은 계정 상세에서 확인합니다.

위젯 편집에서 선택을 비우면 공급자 기본 순서 → 같은 공급자 내 연결 추가 순서입니다. 명시적으로 선택한 계정이 삭제되면 빈 상태를 표시하며 다른 계정으로 대체하지 않습니다. 15분 경과 또는 리셋 도달 후 `이전 관찰`을 표시하며, 지난 리셋을 사용량 0으로 바꾸지 않습니다. 앱은 조회 결과를 저장하고 위젯 reload를 요청하지만 실제 표시 갱신은 WidgetKit 예산에 따릅니다. **위젯을 단순히 보는 이벤트와 정확한 1분 갱신은 WidgetKit에서 보장되지 않습니다.** 위젯을 누르면 앱을 열어 즉시 조회하며, 앱 종료 중에는 1분 수집을 하지 않습니다.

## 저장과 개인정보

- 설정: `~/Library/Application Support/AI Limit/connections-v1.json`. 파일명은 유지하되 schemaVersion **2**로 atomic 저장합니다. v1 연결 ID와 pin을 마이그레이션하고, 중복/잘못된 ID·알 수 없는 schema는 거절합니다. 손상된 설정은 자동 덮어쓰기하지 않고 재설정 동작을 제공합니다.
- 직접 인증 토큰과 수동 세션: 앱 전용 Keychain generic-password, service `dev.bazzi.ai-limit.credentials`, account는 **로컬 연결 ID**입니다. 기존 단일 연결만 공급자 ID 키를 그대로 유지하며 새 계정은 별도 UUID 키를 사용합니다. access/refresh·만료·계정 binding·project·AWS 동적 client 등록 정보를 계정별 credential 레코드에 저장합니다. 설정에는 `directAuthentication` 모드와 비밀 없는 참조만 둡니다. 다른 앱의 인증 저장소를 읽거나 복사하지 않습니다.
- 공유 파일: App Group의 `snapshot-v1.json`, schemaVersion **2**, ISO8601 날짜. v1도 읽으며 계정 ID·사용자가 정한 표시 이름·계정별 관찰을 공유합니다. 공급자 이메일·조직/원격 계정 ID·credential·로컬 경로는 자동 공유하지 않습니다. 표시 이름에 사용자가 직접 입력한 내용은 위젯에도 표시됩니다.
- HTTP: 허용된 HTTPS origin만, ephemeral session, cookie/cache 저장 없음, cross-origin redirect 거부, 20초/2 MiB 제한. 원본 body/header/stderr를 로그에 남기지 않습니다.
- CLI: 인수 배열과 앱 전용 runtime 디렉터리를 사용합니다. 환경은 HOME/TMPDIR/LANG/PATH와 명시적 CODEX_HOME만 전달합니다. GH_TOKEN/API 키/디버그·프록시 환경변수는 상속하지 않습니다. stdout/stderr 각각 1 MiB; 기본 30초, Kiro 20초, Antigravity usage 90초. 취소/timeout은 자신이 시작한 child만 TERM→1초 후 KILL하고 종료를 기다립니다.
- 로그인 취소·서비스 전환·창 닫기·정상 종료에서 인증을 취소하고, commit 시작 후에는 저장을 마칩니다. 첫 연결 동의 전에는 Keychain/인증 endpoint를 읽지 않습니다. 이미 연결에 동의한 계정은 시작 시 자동 갱신됩니다.
- 연결 해제는 진행 중 갱신을 먼저 중지·drain한 다음 앱의 설정·Keychain·snapshot에서 제거합니다. 공급자 서버의 승인 권한은 별도 철회가 필요합니다. 기존 CLI 로그인 파일이나 원본 로그는 삭제하지 않습니다. 기존 연결에서 `directAuthentication`이 없으면 자동 인증이나 credential 변환을 하지 않습니다.

## 소스 구성과 계약 근거

`Sources/AILimitShared`는 Codable 모델·표시 함수·widget reader, `Sources/AILimitCore`는 연결/보안 transport/9개 adapter/coordinator/local scanner, `App`은 SwiftUI 메뉴·설정, `WidgetExtension`은 AppIntent 기반 확장입니다. `Tests/AILimitCoreTests/Fixtures`의 응답은 공개 계약을 바탕으로 만든 비밀 없는 합성 자료이며 Release 앱에는 포함하지 않습니다.

주요 공개 근거(비공식 endpoint의 가용성을 보증하지 않음):
[Codex 공식 transport](https://learn.chatgpt.com/docs/app-server), [Codex account 타입](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/src/protocol/v2/account.rs), [Claude notes](https://github.com/steipete/CodexBar/blob/main/docs/claude.md), [Antigravity usage parser](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Antigravity/AntigravityQuotaSummaryParser.swift), [Cursor 단위](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Cursor/CursorStatusProbe%2BUsageSummary.swift), [gh api](https://cli.github.com/manual/gh_api), [Copilot 계약](https://github.com/steipete/CodexBar/blob/main/docs/copilot.md), [Windsurf wire 계약](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Providers/Windsurf/WindsurfWebFetcher.swift), [Perplexity 필드](https://github.com/steipete/CodexBar/blob/main/Sources/CodexBarCore/Resources/Plugins/perplexity.js), [Grok 제약](https://github.com/steipete/CodexBar/blob/main/docs/grok.md), [Kiro 출력](https://github.com/steipete/CodexBar/blob/main/docs/kiro.md), [WidgetKit 갱신 예산](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date).
