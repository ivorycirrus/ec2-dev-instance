# ec2-dev-instance

AWS에 개발용 EC2 인스턴스 한 대를 만드는 배포 스크립트입니다.

- 인스턴스는 프라이빗 서브넷에 들어가고, NAT 게이트웨이를 통해 인터넷에 나갑니다.
- 접속은 Systems Manager를 통한 SSH로만 합니다. 키 페어와 인바운드 포트는 없습니다.
- 최초 부팅 때 user data가 개발 환경을 설치합니다. Python, Node.js, zsh, tmux, git, kiro-cli, herdr, powerlevel10k(선택)가 들어갑니다.
- VPC, 서브넷, IAM Role은 이름으로 찾아서 있으면 재사용하고, 없으면 CloudFormation 스택으로 만듭니다.

## 빠른 시작

```bash
git clone git@github.com:ivorycirrus/ec2-dev-instance.git
cd ec2-dev-instance
vi src/deploy.sh        # 상단 설정 영역 수정
scripts/build.sh        # dist/deploy.sh 생성
dist/deploy.sh          # 계획과 변경 세트를 확인하고 y 입력
```

배포가 끝나면 인스턴스 ID와 접속 명령이 출력됩니다. SSH 접속 설정은 아래 "접속 (로컬 PC)"을 참고하세요.

## 구성

```
.
├── src/
│   ├── deploy.sh             설정(상단 export 영역), 리소스 조회, AMI 선택, user data 조립, 변경 세트 확인 후 배포
│   ├── ec2-ssh-remote.yaml   CloudFormation 템플릿. deploy.sh가 조회 결과를 파라메터로 넘김. 단독 배포용이 아님
│   └── user-data.sh          최초 부팅 때 실행되는 개발 환경 설치 스크립트
├── scripts/
│   └── build.sh              src/의 세 파일을 dist/deploy.sh 하나로 병합
└── dist/
    └── deploy.sh             빌드 결과. 이 파일 하나만 있으면 어디서든 실행됨. 직접 고치지 않음
```

`dist/`는 빌드할 때마다 다시 만들어지므로 `.gitignore`에 들어 있습니다.

## 빌드

```bash
scripts/build.sh
```

어느 디렉터리에서 실행해도 저장소 루트의 `src/`를 읽고 `dist/deploy.sh`를 씁니다.

`src/deploy.sh` 끝의 `# @embed <파일>` 표시가 붙은 함수(`template`, `user_data`)를, 해당 파일 내용을 heredoc으로 출력하는 함수로 바꿔서 `dist/deploy.sh`를 만듭니다. `dist/deploy.sh`는 실행할 때 두 내용을 임시 디렉터리에 써서 사용하고, 끝나면 지웁니다.

빌드는 결과물의 문법(`bash -n`)을 검사하고, 각 함수가 원본 파일을 바이트 단위로 똑같이 출력하는지 확인한 뒤에만 `dist/deploy.sh`를 교체합니다.

개발 중에는 빌드 없이 `src/deploy.sh`를 바로 실행해도 됩니다. 이때는 옆에 있는 두 파일을 읽습니다.

## 사용법

1. `src/deploy.sh` 상단의 설정 영역을 고치고 `scripts/build.sh`를 실행합니다.
2. `dist/deploy.sh`를 실행합니다. 다른 PC로 이 파일만 복사해서 실행해도 됩니다. 계획과 CloudFormation 변경 세트를 보여준 뒤 `y`를 입력해야 적용합니다.
3. 설정을 바꾼 뒤 다시 빌드하고 실행하면 같은 스택이 업데이트됩니다.

삭제는 `aws cloudformation delete-stack --region ap-northeast-2 --stack-name ec2-ssh-remote`입니다. 스택이 만든 리소스만 지워지고, 재사용한 기존 VPC, 서브넷, Role은 그대로 남습니다.

## 설정

| 변수 | 기본값 | 동작 |
|---|---|---|
| `AWS_REGION` | `ap-northeast-2` | |
| `STACK_NAME` | `ec2-ssh-remote` | 스택 하나에 인스턴스 하나. 인스턴스를 하나 더 만들려면 이 값을 바꿉니다 |
| `INSTANCE_NAME` | `ec2-ssh-remote` | Name 태그 |
| `INSTANCE_TYPE` | `m8g.xlarge` | 이 타입의 CPU 아키텍처(arm64/x86_64)에 맞는 최신 AL2023 AMI를 자동으로 고릅니다 |
| `VOLUME_SIZE` | `40` | 루트 gp3 볼륨(GiB) |
| `VPC_NAME` | `ec2-ssh-remote-vpc` | Name 태그로 찾아서 있으면 재사용, 없으면 생성 |
| `VPC_CIDR` | `10.0.0.0/16` | VPC를 새로 만들 때만 사용 |
| `SUBNET_NAME` | `ec2-ssh-remote-private` | VPC 안에서 Name 태그로 찾아서 있으면 재사용, 없으면 NAT 경유 프라이빗 서브넷을 생성 |
| `AVAILABILITY_ZONE` | 빈 값 | 서브넷을 새로 만들 때만 사용. 비우면 `INSTANCE_TYPE`을 제공하는 첫 AZ |
| `ROLE_NAME` | `ec2-ssh-remote-role` | 있으면 재사용, 없으면 `AmazonSSMManagedInstanceCore`, `AWSCodeCommitPowerUser`, `AmazonS3FullAccess`를 붙여 생성 |
| `TARGET_USER` ~ `GIT_USER_EMAIL` | | user data 설정값. 아래 "User data" 참고 |

### 있으면 재사용, 없으면 생성하는 규칙

- **VPC가 없을 때:** VPC, 인터넷 게이트웨이, 퍼블릭 서브넷, NAT 게이트웨이, 프라이빗 서브넷을 모두 만듭니다. 서브넷 CIDR은 `VPC_CIDR` 안에서 `/24` 두 개를 씁니다.
- **VPC는 있고 서브넷이 없을 때:** 그 VPC에 프라이빗 서브넷을 만듭니다. CIDR은 기존 서브넷과 겹치지 않는 블록을 자동으로 고릅니다(`/24` 우선, 자리가 없으면 `/28`까지 작게). 이때 NAT 게이트웨이는 VPC에 있으면 재사용하고, 없으면 퍼블릭 서브넷과 함께 만듭니다. 인터넷 게이트웨이도 붙어 있는 것이 있으면 재사용합니다.
- **서브넷이 있을 때:** 그대로 씁니다. `0.0.0.0/0` 경로가 NAT로 향하지 않으면 경고를 출력합니다. 인스턴스에 퍼블릭 IP가 없으므로 NAT나 VPC 엔드포인트가 없으면 SSM에 연결되지 않습니다.
- **Role이 있을 때:** 신뢰 정책에 `ec2.amazonaws.com`이 없으면 중단합니다. `AmazonSSMManagedInstanceCore`가 붙어 있지 않으면 경고합니다. 정책을 추가로 붙이지는 않습니다.
- **스택이 만든 리소스:** 다시 실행할 때 이름으로 찾은 리소스가 이 스택이 만든 것이면 계속 스택이 관리합니다. 이 경우 CIDR과 AZ는 현재 값을 유지하고, 바뀐 `VPC_CIDR`이나 `AVAILABILITY_ZONE`은 경고와 함께 무시합니다.

같은 이름의 VPC나 서브넷이 둘 이상 있으면 중단합니다.

## User data

`src/user-data.sh`는 최초 부팅 때 한 번만 실행됩니다.

설정값은 `src/deploy.sh` 상단에서만 관리합니다. `user-data.sh`의 settings 블록에는 값 없이 `NAME="${NAME:?}"` 형태로 쓰는 변수만 나열되어 있습니다. `deploy.sh`는 이 줄들을 찾아서 같은 이름의 설정값을 shebang 바로 아래에 `NAME=값` 줄로 넣습니다. 설정 영역에 없는 이름이 있으면 배포 전에 중단합니다.

| 변수 | 기본값 | 동작 |
|---|---|---|
| `TARGET_USER` | `ec2-user` | 개발 환경을 설치할 사용자. 로그인 셸을 zsh로 바꿉니다 |
| `NODE_MAJOR` | `22` | Node.js 메이저 버전. AL2023은 20, 22, 24 제공 |
| `PYTHON_VER` | `3.14` | Python 버전. AL2023은 3.11 ~ 3.14 제공. `python` alias가 이 버전을 가리킵니다 |
| `SWAP_SIZE_MB` | `2048` | 스왑 파일 크기. `0`이면 만들지 않습니다 |
| `INSTALL_DOCKER` | `false` | `true`면 Docker를 설치하고 `TARGET_USER`를 docker 그룹에 넣습니다 |
| `INSTALL_P10K` | `true` | powerlevel10k 프롬프트와 `~/.p10k.zsh` 설정 |
| `GIT_USER_NAME`, `GIT_USER_EMAIL` | `YOUR-NAME`, `YOUR-EMAIL` | 인스턴스의 git 사용자 정보. 본인 정보로 바꾸세요. 비우면 설정하지 않습니다 |

설치 로그는 인스턴스의 `/var/log/devenv-setup.log`에 남고, 끝나면 `/var/lib/devenv-setup.done` 파일이 생깁니다.

설정을 새로 추가하려면 두 곳을 고칩니다.

1. `src/user-data.sh` settings 블록에 `NEW_SETTING="${NEW_SETTING:?}"` 줄을 추가합니다. 빈 값을 허용하려면 `"${NEW_SETTING?}"`로 씁니다.
2. `src/deploy.sh` 설정 영역에 `export NEW_SETTING="값"`을 추가합니다.

EC2 user data 한도는 16 KB입니다. 조립한 결과가 이를 넘으면 gzip으로 압축해서 보냅니다(cloud-init이 풀어서 실행). 지금은 설정 줄을 포함해 약 14.5 KB라 압축 없이 들어갑니다.

## 스택 업데이트 시 주의

- **인스턴스 교체:** AMI, `VOLUME_SIZE`, 서브넷, AZ가 바뀌면 인스턴스가 교체되고 루트 볼륨이 삭제됩니다. `deploy.sh`는 변경 세트에서 교체되는 리소스를 찾아 적용 전에 경고합니다.
- **AMI 고정:** 업데이트할 때는 아키텍처가 같으면 스택의 현재 AMI를 그대로 씁니다. 새 AL2023 AMI가 나왔다는 이유만으로 인스턴스가 교체되지는 않습니다. 아키텍처가 다른 타입으로 바꾸면 새 AMI가 선택되고 인스턴스가 교체됩니다.
- **User data 변경:** 인스턴스가 중지 후 재시작되지만 새 user data는 실행되지 않습니다. 변경 세트 확인 단계에서 경고합니다.
- **디스크 늘리기:** `VOLUME_SIZE`를 바꾸면 인스턴스가 교체됩니다. 데이터를 유지하려면 `aws ec2 modify-volume`으로 볼륨을 늘리고 인스턴스 안에서 파일시스템을 확장하세요.

## 배포하는 사람에게 필요한 권한

CloudFormation 스택 생성/변경, VPC·서브넷·NAT·EIP·보안 그룹·인스턴스 생성, IAM Role/Instance Profile 생성과 `iam:PassRole`, `ssm:GetParameter`(AMI 조회), 각종 `ec2:Describe*`, `iam:GetRole`. 스택이 IAM Role에 이름을 붙여 만들기 때문에 `CAPABILITY_NAMED_IAM`으로 배포합니다.

## 접속 (로컬 PC)

1. AWS CLI v2와 [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)을 설치합니다.
2. 접속하는 IAM 사용자/Role에 아래 권한이 있어야 합니다.

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": "ssm:StartSession",
         "Resource": [
           "arn:aws:ec2:*:*:instance/*",
           "arn:aws:ssm:*::document/AWS-StartSSHSession"
         ]
       },
       {
         "Effect": "Allow",
         "Action": ["ssm:TerminateSession", "ssm:ResumeSession"],
         "Resource": "arn:aws:ssm:*:*:session/*"
       },
       {
         "Effect": "Allow",
         "Action": "ec2-instance-connect:SendSSHPublicKey",
         "Resource": "arn:aws:ec2:*:*:instance/*",
         "Condition": { "StringEquals": { "ec2:osuser": "ec2-user" } }
       }
     ]
   }
   ```

3. `~/.ssh/config`에 추가합니다. 키 페어 없이 접속하기 위해, 접속할 때마다 EC2 Instance Connect로 내 공개키를 60초 동안 인스턴스에 넣은 뒤 SSM 터널로 SSH를 엽니다. Amazon Linux 2023에는 EC2 Instance Connect가 기본 설치되어 있습니다.

   ```
   Host i-*
       User ec2-user
       IdentityFile ~/.ssh/id_ed25519
       ProxyCommand sh -c "aws ec2-instance-connect send-ssh-public-key --region ap-northeast-2 --instance-id %h --instance-os-user %r --ssh-public-key file://$HOME/.ssh/id_ed25519.pub > /dev/null && aws ssm start-session --region ap-northeast-2 --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p"
   ```

   리전은 설정의 `AWS_REGION`과 맞춥니다. 로컬에 키가 없으면 `ssh-keygen -t ed25519`로 만듭니다.

4. `ssh i-0123456789abcdef0`으로 접속합니다. 인스턴스 ID는 `deploy.sh`가 마지막에 출력합니다. VS Code Remote-SSH도 같은 설정으로 동작합니다.

SSH 없이 셸만 필요하면 `aws ssm start-session --region ap-northeast-2 --target i-0123456789abcdef0`을 쓰면 됩니다.

## 비용

VPC나 NAT 게이트웨이를 새로 만들면 NAT 게이트웨이(시간당 요금 + 처리량 요금)와 퍼블릭 IPv4(EIP) 요금이 인스턴스와 별도로 나옵니다. 기존 VPC의 NAT 게이트웨이를 재사용하면 이 비용은 늘지 않습니다.
