install_subcommand() {
  ### Preparation ###
  parse_args "${@}"
  validate_args
  prepare_environment

  ### Validate ###
  validate

  ### Configure ###
  configure_package
  post_process_istio_yamls

  install
}

install() {
  install_ca
  install_control_plane

  outro
  info "Successfully installed ASM."
  return 0
}

install_in_cluster_control_plane() {
  local PARAMS; PARAMS="$(gen_install_params)"

  if [[ "${_CI_NO_REVISION}" -ne 1 ]]; then
    PARAMS="${PARAMS} --set revision=${REVISION_LABEL}"
  fi

  PARAMS="${PARAMS} --skip-confirmation"

  info "Installing ASM control plane..."
  # shellcheck disable=SC2086
  retry 5 istioctl install $PARAMS

  # Prevent the stderr buffer from ^ messing up the terminal output below
  sleep 1
  info "...done!"
}

install_private_ca() {
  # This sets up IAM privileges for the project to be able to access GCP CAS.
  # If modify_gcp_component permissions are not granted, it is assumed that the
  # user has taken care of this, else Istio setup will fail
  local CA_NAME; CA_NAME="$(context_get-option "CA_NAME")"
  local CA_POOL_URI; CA_POOL_URI=$(echo "${CA_NAME}" | cut -f1 -d:)
  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"
  local WORKLOAD_IDENTITY; WORKLOAD_IDENTITY="${FLEET_ID}.svc.id.goog:/allAuthenticatedUsers/"
  local CA_LOCATION; CA_LOCATION=$(echo "${CA_POOL_URI}" | cut -f4 -d/)
  local CA_POOL; CA_POOL=$(echo "${CA_POOL_URI}" | cut -f6 -d/)
  local PROJECT; PROJECT=$(echo "${CA_POOL_URI}" | cut -f2 -d/)

  if can_modify_gcp_iam_roles; then
    retry 3 gcloud privateca pools add-iam-policy-binding "${CA_POOL}" \
      --project "${PROJECT}" \
      --location "${CA_LOCATION}" \
      --member "group:${WORKLOAD_IDENTITY}" \
      --role "roles/privateca.workloadCertificateRequester"

    retry 3 gcloud privateca pools add-iam-policy-binding "${CA_POOL}" \
      --project "${PROJECT}" \
      --location "${CA_LOCATION}" \
      --member "group:${WORKLOAD_IDENTITY}" \
      --role "roles/privateca.auditor"

    if [[ "${CA_NAME}" == *":"* ]]; then
      local CERT_TEMPLATE; CERT_TEMPLATE=$(echo "${CA_NAME}" | cut -f2 -d:)
      retry 3 gcloud privateca templates add-iam-policy-binding "${CERT_TEMPLATE}" \
        --member "group:${WORKLOAD_IDENTITY}" \
        --role "roles/privateca.templateUser"
    fi
  fi
}

does_istiod_exist(){
  local RETVAL; RETVAL=0;
  kubectl get service \
    --request-timeout='20s' \
    -n istio-system \
    istiod 1>/dev/null 2>/dev/null || RETVAL=$?
  return "${RETVAL}"
}

apply_kube_yamls() {
  for yaml_file in $(context_list "kubectlFiles"); do
    info "Applying ${yaml_file}..."
    retry 3 kubectl apply --overwrite=true -f "${yaml_file}"
    sleep 2
  done
}

verify_canonical_controller() {
  local MIGRATION_DOC_LINK="https://cloud.google.com/service-mesh/docs/canonical-service-migrate-from-in-cluster-controller"
  local IN_CLUSTER_CSC_DEP; IN_CLUSTER_CSC_DEP="$(kubectl get deployment/canonical-service-controller-manager \
    -n asm-system --ignore-not-found=true || true)"
  if [[ -z "$IN_CLUSTER_CSC_DEP" ]]; then
    info "Checking Managed CanonicalService controller state..."
    check_managed_canonical_controller_state
  else
    warn "In-cluster canonical service controller is deprecated, please upgrade to managed canonical service controller. Please refer to ${MIGRATION_DOC_LINK}"
    info "Updating ASM CanonicalService controller in asm-system namespace..."
    retry 3 kubectl apply -f "${CANONICAL_CONTROLLER_MANIFEST}"
    info "Waiting for deployment..."
    retry 3 kubectl wait --for=condition=available --timeout=600s \
      deployment/canonical-service-controller-manager -n asm-system
  fi
  info "...done!"
}

install_fleet_api() {
  local PROJECT_ID; PROJECT_ID="$(context_get-option "PROJECT_ID")"
  local CLUSTER_NAME; CLUSTER_NAME="$(context_get-option "CLUSTER_NAME")"
  local CLUSTER_LOCATION; CLUSTER_LOCATION="$(context_get-option "CLUSTER_LOCATION")"
  local MEMBERSHIP_NAME; MEMBERSHIP_NAME="$(generate_membership_name "${PROJECT_ID}" "${CLUSTER_LOCATION}" "${CLUSTER_NAME}")"

  local FLEET_ID; FLEET_ID="$(context_get-option "FLEET_ID")"

  local MEMBERSHIP_LOCATION
  MEMBERSHIP_LOCATION="$(gcloud container fleet memberships list \
    --project "${FLEET_ID}" \
    --filter=name:"${MEMBERSHIP_NAME}" \
    --format=json | jq .[].name | sed 's/^.*locations\/\(.*\)\/memberships.*/\1/')"

  info "Calling Fleet API to enable control plane management..."
  run_command gcloud container fleet mesh update \
     --management automatic \
     --memberships "${MEMBERSHIP_NAME}" \
     --project "${FLEET_ID}" \
     --location "${MEMBERSHIP_LOCATION}"

  local LIMIT; LIMIT=5
  info "Waiting for revision to become ready (${LIMIT} minutes)..."
  for i in $(seq 0 "${LIMIT}"); do
    if ! gcloud container fleet mesh describe --project "${FLEET_ID}" --format=json | \
      jq '.membershipStates | with_entries(select(.key|test("'"${MEMBERSHIP_NAME}"'")))[].servicemesh.controlPlaneManagement' | \
      grep -q "REVISION_READY"; then
      echo -n "."
      sleep 60
    else break
    fi
    if [[ "${i}" -eq "${LIMIT}" ]]; then
      warn "Not ready after ${LIMIT} minutes. Installation may eventually be successful."
    fi
  done
  info "...done!"
}

install_control_plane_revision() {
  info "Configuring ASM managed control plane revision CR..."

  local CHANNEL CR REVISION SPECIFIED_CHANNEL
  CHANNEL="$(get_cr_channel)"
  SPECIFIED_CHANNEL="$(context_get-option "CHANNEL")"

  read -r CR REVISION<<EOF
$(get_cr_yaml "${CHANNEL}")
EOF
  info "Installing ASM Control Plane Revision CR with ${REVISION} channel in istio-system namespace..."
  retry 3 kubectl apply -f "${CR}"

  if [[ -n "${SPECIFIED_CHANNEL}" && "${SPECIFIED_CHANNEL}" != "${CHANNEL}" ]]; then
    info "Adding tag for ${SPECIFIED_CHANNEL}..."
    local TAG_NAME; TAG_NAME="$(map_channel_name "${SPECIFIED_CHANNEL}")"
    kubectl annotate -f "${CR}" "mesh.cloud.google.com/tags=${TAG_NAME}"
  fi

  info "Waiting for deployment..."
  retry 3 kubectl wait --for=condition=ProvisioningFinished \
    controlplanerevision "${REVISION}" -n istio-system --timeout 600s
}

map_channel_name() {
  case "${1}" in
    regular) echo "asm-managed";;
    rapid) echo "asm-managed-rapid";;
    stable) echo "asm-managed-stable";;
  esac
}

expose_istiod() {
  # The default istiod service is exposed so that any fallback on the VM side
  # to use the default Istiod service can still connect to the control plane.
  context_append "kubectlFiles" "${EXPOSE_ISTIOD_DEFAULT_SERVICE}"
  context_append "kubectlFiles" "${EXPOSE_ISTIOD_REVISION_SERVICE}"
}

outro() {
  local OUTPUT_DIR; OUTPUT_DIR="$(context_get-option "OUTPUT_DIR")"
  local CHANNEL; CHANNEL="$(context_get-option "CHANNEL")"
  local MANAGED_REVISION_LABEL; MANAGED_REVISION_LABEL="${REVISION_LABEL}"
  if is_managed; then
    case "${CHANNEL}" in
    regular)
      MANAGED_REVISION_LABEL="${REVISION_LABEL_REGULAR}"
      ;;
    stable)
      MANAGED_REVISION_LABEL="${REVISION_LABEL_STABLE}"
      ;;
    rapid)
      MANAGED_REVISION_LABEL="${REVISION_LABEL_RAPID}"
      ;;
    esac
  fi

  info ""
  info "$(starline)"
  istioctl version
  info "$(starline)"
  info "The ASM control plane installation is now complete."
  info "To enable automatic sidecar injection on a namespace, you can use the following command:"
  info "kubectl label namespace <NAMESPACE> istio-injection- istio.io/rev=${MANAGED_REVISION_LABEL} --overwrite"
  info "If you use 'istioctl install' afterwards to modify this installation, you will need"
  info "to specify the option '--set revision=${MANAGED_REVISION_LABEL}' to target this control plane"
  info "instead of installing a new one."

  info "To finish the installation, enable Istio sidecar injection and restart your workloads."
  info "For more information, see:"
  info "https://cloud.google.com/service-mesh/docs/proxy-injection"

  info "The ASM package used for installation can be found at:"
  info "${OUTPUT_DIR}/asm"
  info "The version of istioctl that matches the installation can be found at:"
  info "${OUTPUT_DIR}/${ISTIOCTL_REL_PATH}"
  info "A symlink to the istioctl binary can be found at:"
  info "${OUTPUT_DIR}/istioctl"
  if ! is_managed; then
    info "The combined configuration generated for installation can be found at:"
    info "${OUTPUT_DIR}/${RAW_YAML}"
    info "The full, expanded set of kubernetes resources can be found at:"
    info "${OUTPUT_DIR}/${EXPANDED_YAML}"
  fi

  info "$(starline)"
}

configure_ca() {
  local CA; CA="$(context_get-option "CA")"
  case "${CA}" in
    mesh_ca) configure_meshca;;
    gcp_cas) configure_private_ca;;
    managed_cas) x_configure_managed_cas;;
    citadel) configure_citadel;;
  esac
}

configure_control_plane() {
  :
}

install_ca() {
  local CA; CA="$(context_get-option "CA")"
  case "${CA}" in
    mesh_ca) ;;
    gcp_cas) install_private_ca;;
    citadel) install_citadel;;
  esac
}

install_control_plane() {
  label_istio_namespace
  if is_managed; then
    install_managed_control_plane
  else
    install_in_cluster_control_plane
  fi

  apply_kube_yamls

  if is_managed; then
    if use_fleet_api; then install_fleet_api; else install_control_plane_revision; fi
  fi

  verify_canonical_controller
}
