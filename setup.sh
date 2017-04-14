#!/usr/bin/env bash

[[ "$TRACE" = "true" ]] && set -x

set -e

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "$BASE_DIR"

BIN_DIR="$BASE_DIR/bin"
LIB_DIR="$BASE_DIR/lib"

export PATH="$BIN_DIR:$PATH"

info() {
  echo -e "\033[1;30m$*\033[m"
}

success() {
  echo -e "\033[1;32m$*\033[m"
}

error() {
  >&2 echo -e "\033[1;31m$*\033[m"
  exit 1
}

create_dirs() {
  mkdir -p "$BIN_DIR" "$LIB_DIR"
}

install_pcfdev() {
  if cf dev > /dev/null; then
    success "PCFDev exists. Moving on..."
  else
    error "PCFDev does not exist. Visit https://network.pivotal.io/products/pcfdev to download and install PCFDev"
  fi
}

start_pcfdev() {
  if cf dev status | grep -i Running; then
    cf dev destroy -f
  fi

  success "Starting PCFDev ..."
  cf dev start -d local.pcfdev.io -i 192.168.11.11 -s none
  success "Done.\n"
}

create_pcf_uaa_client() {
  success "Creating UAA client for cloudcache broker..."

  uaac target uaa.local.pcfdev.io --skip-ssl-validation
  uaac token client get admin --secret admin-client-secret

  if ! uaac clients | grep cloudcache_broker; then
    uaac client add cloudcache_broker \
      --name cloudcache_broker \
      --secret cloudcache_broker-secret \
      --scope uaa.none \
      --authorities cloud_controller.admin \
      --authorized_grant_types "client_credentials,refresh_token"
  fi

  success "Done.\n"
}

install_dependencies() {
  if ! which rq > /dev/null; then
    success "Downloading rq ..."
    curl -L https://github.com/dflemstr/rq/releases/download/v0.10.4/record-query-v0.10.4-x86_64-apple-darwin.tar.gz | \
      tar -zxf- --strip-components=1 -C /usr/local/bin/
    chmod +x /usr/local/bin/rq
    success "Done.\n"
  fi

  if ! which jq > /dev/null; then
    success "Downloading jq ..."
    curl https://github.com/stedolan/jq/releases/download/jq-1.5/jq-osx-amd64 -L -o /usr/local/bin/jq
    chmod +x /usr/local/bin/jq
    success "Done.\n"
  fi

  if ! which gbosh > /dev/null; then
    success "Downloading the new bosh cli (go cli) as \`gbosh\`..."
    curl https://s3.amazonaws.com/bosh-cli-artifacts/bosh-cli-2.0.13-darwin-amd64 -L -o /usr/local/bin/gbosh
    chmod +x /usr/local/bin/gbosh
    success "Done.\n"
  fi
}

fetch_bosh_deployment() {
  pushd "$LIB_DIR" > /dev/null
    if [ ! -d "$LIB_DIR/bosh-deployment" ]; then
      success "Cloning bosh-deployment repo from github..."
      git clone https://github.com/cloudfoundry/bosh-deployment.git
      success "Done.\n"
    fi
  popd > /dev/null
}

setup_vbox_network() {
  success "Adding Nat network to VirtualBox..."

  VBoxManage natnetwork add --netname BoshLiteNatNetwork --network "10.0.3.0/24" --dhcp on || true
  VBoxManage dhcpserver add --netname BoshLiteNatNetwork --enable \
    --ip 10.0.3.3 --lowerip 10.0.3.4 --netmask 255.255.255.0 \
    --upperip 10.0.3.254 || true

  success "Done.\n"
}


deploy_bosh_lite() {
  if [[ ! -f "$LIB_DIR/bosh-deployment/bosh_variables" ]]; then
    local pcfdev_hostonlyif="$(ifconfig | grep -B 2 192.168.11.1 | grep vboxnet | cut -f1 -d':')"
    if [ -z "$pcfdev_hostonlyif" ]; then
      error "PCFDev must be running on the 192.168.11.1 vboxnet
             Please restart PCFDev with the following flags 'cf dev start -d local.pcfdev.io -i 192.168.11.11'"
    fi

    local store_dir="$HOME/.bosh_virtualbox_cpi"

    pushd "$LIB_DIR/bosh-deployment"
      success "Deploying BOSH Lite with garden-runc..."

      gbosh create-env bosh.yml \
        -o virtualbox/cpi.yml \
        -o "$BASE_DIR/vbox-store-dir.yml" \
        -o bosh-lite.yml \
        -o virtualbox/outbound-network.yml \
        -o jumpbox-user.yml \
        -o bosh-lite-runc.yml \
        --vars-store bosh-director-vars \
        -v outbound_network_name=BoshLiteNatNetwork \
        -v director_name=vbox \
        -v internal_ip=192.168.11.2 \
        -v internal_gw=192.168.11.1 \
        -v internal_cidr=192.168.11.0/24 \
        -v network_name="$pcfdev_hostonlyif" \
        -v store_dir="$store_dir"

      success "Done.\n"
    popd

  fi

  pushd "$LIB_DIR/bosh-deployment" > /dev/null
    rq -y < bosh-director-vars | jq -r '.default_ca.ca' > /tmp/director-ca
    rq -y < bosh-director-vars | jq -r '.jumpbox_ssh.private_key' > /tmp/ssh-key

    cat <<EOF > bosh_variables
export BOSH_ENV_NAME=lite
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET="$(rq -y < "$LIB_DIR/bosh-deployment/bosh-director-vars" | jq -r .admin_password)"
export BOSH_ENVIRONMENT=https://192.168.11.2:25555
export BOSH_CA_CERT=/tmp/director-ca
EOF
  popd > /dev/null
}

add_route() {
  success "Adding bosh lite route to local route table ..."

  sudo route delete -net 10.244.0.0/16 192.168.11.2
  sudo route add -net 10.244.0.0/16 192.168.11.2

  success "Done.\n"
}

update_cloud_config() {
  success "Uploading \`$BASE_DIR/cloud-config.yml\` cloud config to the director ..."

  source "$LIB_DIR/bosh-deployment/bosh_variables"
  gbosh -n update-cloud-config "$BASE_DIR/cloud-config.yml"

  success "Done.\n"
}


main() {
  which VBoxManage > /dev/null || error "Please install virtualbox"

  create_dirs

  install_pcfdev

  # start_pcfdev

  # create_pcf_uaa_client

  install_dependencies

  fetch_bosh_deployment

  setup_vbox_network

  deploy_bosh_lite

  add_route

  update_cloud_config

  success "Please run \`source $LIB_DIR/bosh-deployment/bosh_variables\` then use \`gbosh\` to interact with the bosh director."
}

main "$@"
