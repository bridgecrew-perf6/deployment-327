# ---------------------------------------------------------------------------- #

function __resolve()
{
    ( cd "$*" && pwd )
}

function __log()
{
    >&2 echo "$(tput setaf 6)[$( date "+%H:%M:%S" )]$(tput sgr 0) $*"
}

function __notice()
{
    __log "$(tput setaf 3)$*$(tput sgr 0)"
}

function __error()
{
    local -a lines
    readarray -t lines <<< "$*"

    for line in "${lines[@]}"; do
        __log "$(tput setaf 1)Error:$(tput sgr 0) ${line}"
    done
}

function __bad_usage()
{
    >&2 echo "$(tput setaf 1)Error:$(tput sgr 0) $*"
    exit 2
}

function __ensure_option_has_value()
{
    [[ ! -z "${2+x}" ]] || __bad_usage "Missing value for option $1"
}

function __fail()
{
    __error "$@"
    exit 1
}

function __github_resolve_hash()
{
    local result

    if [[ "$2" =~ ^[A-Fa-f0-9]{40}$ ]]; then
        result="$2"
    else
        result=( $( git ls-remote "https://github.com/TuiChain/$1.git" "$2" | cut -f1 ) )
        (( ${#result[@]} == 1 )) || __fail "Couldn't find branch $2 of $1"
    fi

    echo "${result}"
}

function __github_download()
{
    mkdir "$3"
    curl -LsS "https://github.com/TuiChain/$1/archive/$2.tar.gz" |
        tar --strip-components 1 -C "$3" -xzf -
}

function __ether_balance()
{
    python <<EOF
import web3
w3 = web3.Web3(web3.HTTPProvider("$1"))
print(w3.eth.getBalance("$2", "latest"))
EOF
}

function __django_manage()
{
    (
        set -o errexit -o pipefail -o nounset

        export \
            SECRET_KEY \
            DEBUG \
            ALLOWED_HOSTS \
            FRONTEND_DIR \
            DATABASE_ENGINE \
            DATABASE_NAME \
            DATABASE_USER \
            DATABASE_PASSWORD \
            DATABASE_HOST \
            DATABASE_PORT \
            EMAIL_USE_TLS \
            EMAIL_PORT \
            EMAIL_HOST \
            EMAIL_HOST_USER \
            EMAIL_HOST_PASSWORD \
            EMAIL_BACKEND \
            ETHEREUM_PROVIDER \
            ETHEREUM_MASTER_ACCOUNT_PRIVATE_KEY \
            ETHEREUM_CONTROLLER_ADDRESS

        SECRET_KEY=test
        DEBUG=True
        ALLOWED_HOSTS=

        FRONTEND_DIR=

        DATABASE_ENGINE=django.db.backends.sqlite3
        DATABASE_NAME="$( __resolve . )/django-database.sqlite3"
        DATABASE_USER=
        DATABASE_PASSWORD=
        DATABASE_HOST=
        DATABASE_PORT=

        EMAIL_USE_TLS=False
        EMAIL_PORT=2525
        EMAIL_HOST=smtp.mailtrap.io
        EMAIL_HOST_USER=2d9e3ff1649e5b
        EMAIL_HOST_PASSWORD=229c33d92162ba
        EMAIL_BACKEND=django.core.mail.backends.smtp.EmailBackend

        ETHEREUM_PROVIDER="${network_url}"
        ETHEREUM_MASTER_ACCOUNT_PRIVATE_KEY="${keys[0]}"
        ETHEREUM_CONTROLLER_ADDRESS="${controller_contract_address}"

        python "${backend_dir}/manage.py" "$@"
    )
}

# ---------------------------------------------------------------------------- #

function __do_things()
{
    trap '{ [[ -z "$(jobs -p)" ]] || kill -INT $(jobs -p); wait; }' EXIT

    frontend_dir="${frontend_dir:-@main}"
    backend_dir="${backend_dir:-@main}"
    blockchain_dir="${blockchain_dir:-@main}"

    if [[ "${frontend_dir}" == @* ]]; then
        __notice "Frontend:   ${frontend_dir:1} @ https://github.com/TuiChain/frontend"
    else
        frontend_dir="$( __resolve "${frontend_dir}" )"
        __notice "Frontend:   ${frontend_dir}"
    fi

    if [[ "${backend_dir}" == @* ]]; then
        __notice "Backend:    ${backend_dir:1} @ https://github.com/TuiChain/backend"
    else
        backend_dir="$( __resolve "${backend_dir}" )"
        __notice "Backend:    ${backend_dir}"
    fi

    if [[ "${blockchain_dir}" == @* ]]; then
        __notice "Blockchain: ${blockchain_dir:1} @ https://github.com/TuiChain/blockchain"
    else
        blockchain_dir="$( __resolve "${blockchain_dir}" )"
        __notice "Blockchain: ${blockchain_dir}"
    fi

    __notice "Network:    $1"

    # set up virtual environment

    if [[ ! -e "${venv_dir}/pyvenv.cfg" ]]; then
        __log "Creating virtual environment..."
        python3 -m venv "${venv_dir}"
    fi

    venv_dir="$( __resolve "${venv_dir}" )"

    # change working directory to virtual environment directory

    cd "${venv_dir}"

    # run post-venv hook

    "$2"

    # activate virtual environment

    source bin/activate

    # upgrade pip to avoid warnings

    if [[ ! -e pip-upgraded ]]; then
        __log "Upgrading pip..."
        pip -q install -U pip setuptools wheel
        touch pip-upgraded
    fi

    # install blockchain component

    if [[ "${blockchain_dir}" == @* ]]; then

        local blockchain_hash
        blockchain_hash="$( __github_resolve_hash blockchain "${blockchain_dir:1}" )"

        if [[ ! -e blockchain-hash.txt || "$( cat blockchain-hash.txt )" != "${blockchain_hash}" ]]; then
            __log "Installing blockchain component..."
            rm -f blockchain-hash.txt
            ! pip list | grep tuichain-ethereum > /dev/null 2>&1 || pip -q uninstall -y tuichain-ethereum
            pip -q install "https://github.com/TuiChain/blockchain/archive/${blockchain_hash}.tar.gz"
            echo "${blockchain_hash}" > blockchain-hash.txt
        fi

    else

        rm -f blockchain-hash.txt

        __log "Installing blockchain component..."
        ! pip list | grep tuichain-ethereum > /dev/null 2>&1 || pip -q uninstall -y tuichain-ethereum
        pip -q install "${blockchain_dir}"

    fi

    # get backend component

    if [[ "${backend_dir}" == @* ]]; then

        local backend_hash
        backend_hash="$( __github_resolve_hash backend "${backend_dir:1}" )"

        if [[ ! -e backend-hash.txt || "$( cat backend-hash.txt )" != "${backend_hash}" ]]; then
            __log "Downloading backend..."
            rm -f backend-hash.txt
            rm -fr backend
            __github_download backend "${backend_hash}" backend
            echo "${backend_hash}" > backend-hash.txt
        fi

        backend_dir=backend

    else

        rm -f backend-hash.txt
        rm -fr backend

    fi

    if pip freeze -r "${backend_dir}/requirements.txt" 2>&1 > /dev/null |
        grep WARNING: > /dev/null; then
        __log "Installing backend dependencies..."
        pip -q install -r "${backend_dir}/requirements.txt"
    fi

    # generate Ethereum accounts

    if [[ ! -s ethereum-accounts.txt ]]; then

        __log "Generating Ethereum test accounts..."

        for (( i = 0; i < ${num_user_accounts:-0} + 1; ++i )); do
            hexdump -n 32 -e '8/4 "%08x" 1 "\n"' /dev/urandom \
                >> ethereum-accounts.txt
        done

    fi

    keys=( $( cat ethereum-accounts.txt ) )

    addresses=( $( python <<EOF
import tuichain_ethereum as tui

for key in "${keys[*]}".split():
    print(tui.PrivateKey(bytes.fromhex(key)).address)
EOF
) )

    # build frontend

    if [[ "${frontend_dir}" == @* ]]; then

        local frontend_hash
        frontend_hash="$( __github_resolve_hash frontend "${frontend_dir:1}" )"

        if [[ ! -e frontend-hash.txt || "$( cat frontend-hash.txt )" != "${frontend_hash}" ]]; then
            __log "Downloading frontend..."
            rm -f frontend-hash.txt
            rm -fr frontend
            __github_download frontend "${frontend_hash}" frontend
            echo "${frontend_hash}" > frontend-hash.txt
        fi

        frontend_dir=frontend

    else

        rm -f frontend-hash.txt
        rm -fr frontend

    fi

    __log "Installing frontend dependencies..."
    ( cd "${frontend_dir}/web" && npm install --silent )

    # run hook to set up Ethereum network

    "$3"

    # deploy mock ERC-20 Dai contract

    if [[ ! -s ethereum-dai-contract.txt ]]; then

        __log "Deploying mock ERC-20 Dai contract..."

        python <<EOF > ethereum-dai-contract.txt
import web3
import tuichain_ethereum as tui
import tuichain_ethereum.test as tui_test

dai = tui_test.DaiMockContract.deploy(
    provider=web3.HTTPProvider("${network_url}"),
    account_private_key=tui.PrivateKey(bytes.fromhex("${keys[0]}")),
    ).get()

for key in "${keys[*]}".split():

    dai.mint(
        account_private_key=tui.PrivateKey(bytes.fromhex(key)),
        atto_dai=100_000 * (10 ** 18)
        ).get()

print(dai.address)
EOF

    fi

    dai_contract_address="$( cat ethereum-dai-contract.txt )"

    # deploy controller contract

    if [[ ! -s ethereum-controller-contract.txt ]]; then

        __log "Deploying controller contract..."

        python <<EOF > ethereum-controller-contract.txt
import web3
import tuichain_ethereum as tui

transaction = tui.Controller.deploy(
    provider=web3.HTTPProvider("${network_url}"),
    master_account_private_key=tui.PrivateKey(bytes.fromhex("${keys[0]}")),
    dai_contract_address=tui.Address("${dai_contract_address}"),
    market_fee_atto_dai_per_nano_dai=10 ** 7,
    )

print(transaction.get().contract_address)
EOF

    fi

    controller_contract_address="$( cat ethereum-controller-contract.txt )"

    # apply django migrations

    if ! __django_manage migrate --no-input --check > /dev/null 2>&1; then
        __log "Applying Django migrations..."
        __django_manage migrate --no-input
    fi

    # create django superuser account

    local superuser_exists

    superuser_exists="$( cat <<EOF | __django_manage shell
from django.contrib.auth import get_user_model
print(get_user_model().objects.filter(username="admin").exists())
EOF
)"

    if [[ "${superuser_exists}" = False ]]; then

        __log "Creating Django superuser..."

        cat <<EOF | __django_manage shell
from django.contrib.auth import get_user_model
get_user_model().objects.create_superuser("admin", "admin@admin.admin", "admin")
EOF

    fi

    # run django and create-react-app development servers

    __log "Starting Django and Create-React-App development servers..."

    __notice "Create-React-App development server:"
    __notice "     http://localhost:3000/"
    __notice "Django development server:"
    __notice "     http://localhost:8000/"
    __notice "Django superuser:"
    __notice "     Email: admin@admin.admin"
    __notice "     Username: admin"
    __notice "     Password: admin"
    __notice "Ethereum provider:"
    __notice "     ${network_url}"
    __notice "Ethereum Dai contract:"
    __notice "     ${dai_contract_address}"
    __notice "Ethereum controller contract:"
    __notice "     ${controller_contract_address}"
    __notice "Ethereum master account:"
    __notice "     ${addresses[0]}"
    __notice "     ${keys[0]}"

    if (( ${#addresses[@]} > 1 )); then

        __notice "Ethereum user accounts:"

        for (( i = 1; i < ${#addresses[@]}; ++i )); do
            __notice " [$i] ${addresses[i]}"
            __notice "     ${keys[i]}"
        done

    fi

    __django_manage runserver 8000 &

    (
        set -o errexit -o pipefail -o nounset
        cd "${frontend_dir}/web"
        export BROWSER FORCE_COLOR REACT_APP_API_URL
        BROWSER=none
        FORCE_COLOR=true
        REACT_APP_API_URL=http://localhost:8000/api
        npm run start | cat
    ) &

    wait -n
}

# ---------------------------------------------------------------------------- #
