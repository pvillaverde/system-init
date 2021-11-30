#!/bin/sh

# Based on ACKSTORM bootstrap init script: https://git.ackstorm.com/ackstorm-public/init

set +e

# Required for some tools
PATH=$PATH:/usr/local/bin

UPDATE_URL="https://github.com/pvillaverde/system-init/blob/main/init.sh"
PIDFILE="/tmp/docker-init.pid"
BOOTSTRAP_FILE=/.docker-init
DOCKER_BIN=/usr/bin/docker
DOCKER_COMPOSE_BIN=/usr/bin/docker-compose
DOCKER_SOCK=/var/run/docker.sock

DOCKER_COMPOSE_VERSION=1.29.2

HELP=0
UPDATE=0
CLEAN=0
RECREATE=0
BUILD=0
PULL=0
STOP=0

START=1

# Read parameters
while [ $# -gt 0 ]; do
	[ "$1" = "--force" ] && STOP=1 && BUILD=1 && PULL=1 && RECREATE=1 && CLEAN=1
	[ "$1" = "--recreate" ] && STOP=0 && RECREATE=1 && CLEAN=1
	[ "$1" = "--pull" ] && PULL=1 && CLEAN=1
	[ "$1" = "--stop" ] && STOP=1 && START=0
	[ "$1" = "--clean" ] && CLEAN=1 && START=0
	[ "$1" = "--help" ] && HELP=1 && START=0
	[ "$1" = "--update" ] && UPDATE=1 && START=0
	[ "$1" = "--build" ] && BUILD=1
	shift
done

if [ $HELP -gt 0 ]; then
	echo $0: Initialize a system using docker-compose file
	echo "  --pull: Update images from remote registry"
	echo "  --stop: Stop docker-compose containers"
	echo "  --clean: Clean unused images"
	echo "  --build: build images refernced in docker-compose"
	echo "  --recreate: Adds --force-recreate when calling docker-compose"
	echo "  --force: Makes --pull --clean --build and --recreate"
	exit
fi

_lock() {
	if [ -e ${PIDFILE} ]; then
		OTHERPID="$(cat "${PIDFILE}")"
		if [ $? != 0 ]; then
			echo "lock failed, PID ${OTHERPID} is active" >&2
			exit 1
		fi

		if [ ! -d /proc/${OTHERPID} ]; then
			# lock is stale, remove it and restart
			echo "Removing stale lock of nonexistant PID ${OTHERPID}" >&2
			rm -rf "${PIDFILE}" >/dev/null 2>&1 || /bin/true

		else
			# lock is valid and OTHERPID is active - exit, we're locked!
			echo "Lock failed, PID ${OTHERPID} is active" >&2
			exit 1
		fi
	fi

	# write lock file
	echo "$$" >${PIDFILE}
}

_unlock() {
	rm -rf ${PIDFILE} >/dev/null 2>&1 || /bin/true
}

_wait_for_network() {
	while ! ping -c 1 -W 1 8.8.8.8 >/dev/null; do
		echo "Waiting for 8.8.8.8 - network interface might be down..."
		sleep 1
	done
}

_clean_images() {
	rm /tmp/run_image_ids.$$ >/dev/null 2>&1

	$DOCKER_BIN ps --no-trunc -a -q | while read cid; do
		running=$($DOCKER_BIN inspect -f '{{.State.Running}}' $cid)

		if [ "$running"x = "true"x ]; then
			id=$($DOCKER_BIN inspect -f '{{.Image}}' $cid)
			echo $id >>/tmp/run_image_ids.$$
			continue
		fi

		fini=$($DOCKER_BIN inspect -f '{{.State.FinishedAt}}' $cid | awk -F. '{print $1}')
		diff=$(expr $(date +"%s") - $(date --date="$fini" +"%s"))

		if [ $diff -gt 86400 ]; then
			$DOCKER_BIN rm -v $cid 2>&1
		fi
	done

	$DOCKER_BIN images --no-trunc | grep -v REPOSITORY | while read line; do
		repo_tag=$(echo $line | awk '{print $1":"$2}')
		image_id=$(echo $line | awk '{print $3}')
		grep -q $image_id /tmp/run_image_ids.$$ >/dev/null 2>&1

		if [ $? -eq 0 ]; then
			continue
		fi

		if [ "$repo_tag"x = "<none>:<none>"x ]; then
			$DOCKER_BIN rmi $image_id >/dev/null 2>&1

		else
			$DOCKER_BIN rmi $repo_tag >/dev/null 2>&1
		fi
	done

	rm /tmp/run_image_ids.$$ >/dev/null 2>&1
}

_bootstrap() {
	echo -n "Bootstrapping system..."

	# Prepare and update
	export DEBIAN_FRONTEND=noninteractive
	export CHANNEL=stable

	apt-get update
	apt-get install -qy curl || yum install -y curl

	# Install docker
	curl -sSL https://get.docker.com/ | /bin/sh

	# Install docker-compose
	curl -L https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m) >${DOCKER_COMPOSE_BIN}
	chmod +x ${DOCKER_COMPOSE_BIN}

	# Self copy to working directory
	if [ ! -e /root/init/init.sh ]; then
		mkdir /root/init 2>/dev/null
		cat $0 >/root/init/init.sh
		chmod 750 /root/init/init.sh
	fi

	# Execute on next boot (and restart telegraf to get new hostname to avoid dup on instance clone)
	echo "@reboot root docker rm -f telegraf; /root/init/init.sh --pull >> /root/init/init.log 2>&1" >/etc/cron.d/docker-init

	# Add daily update for containers
	echo "00 08 * * * root /root/init/init.sh --pull >> /root/init/init.log 2>&1" >/etc/cron.d/docker-init-update

	# Mark as done
	echo "Don't remove me" >${BOOTSTRAP_FILE}
	service docker restart
	echo "done"
}

_apply_fixes() {
	if [ -e /etc/cron.d/docker-init ]; then
		sed -i -e 's|--force|--pull|' /etc/cron.d/docker-init
	fi
}

_download_compose_gcp() {
	# Get metadata (GCP)
	REMOTE_COMPOSE_YAML=$(curl -f "http://metadata.google.internal/computeMetadata/v1/instance/attributes/startup-compose-file" -H "Metadata-Flavor: Google" 2>/dev/null)

	if [ $? = 0 ] && [ -n "${REMOTE_COMPOSE_YAML}" ]; then
		PROTO=$(echo ${REMOTE_COMPOSE_YAML} | cut -c1-5)
		echo -n "Downloading remote docker compose from: ${REMOTE_COMPOSE_YAML}..."
		if [ "gs://" = "${PROTO}" ]; then
			gsutil cp ${REMOTE_COMPOSE_YAML} /root/init/docker-compose.yml >/dev/null 2>&1
			echo "Done"

		else
			echo "Failed: Unable to get external file"
			exit 1
		fi
	fi
}

_download_sysctl_gcp() {
	# Get metadata (GCP)
	REMOTE_SYSCTL_YAML=$(curl -f "http://metadata.google.internal/computeMetadata/v1/instance/attributes/startup-sysctl-file" -H "Metadata-Flavor: Google" 2>/dev/null)

	if [ $? = 0 ] && [ -n "${REMOTE_SYSCTL_YAML}" ]; then
		PROTO=$(echo ${REMOTE_SYSCTL_YAML} | cut -c1-5)
		echo -n "Downloading remote sysctl from: ${REMOTE_SYSCTL_YAML}..."
		if [ "gs://" = "${PROTO}" ]; then
			gsutil cp ${REMOTE_SYSCTL_YAML} /etc/sysctl.conf
			sysctl -p
			echo "Done"

		else
			echo "Failed: Unable to get external file"
			exit 1
		fi
	fi
}

_aws_get_region() {
	REGION=$(curl --silent http://instance-data/latest/dynamic/instance-identity/document | jq -r .region)
	if [ "" = "${REGION}" ]; then
		# Metadata v2
		TOKEN=$(curl --silent -X PUT "http://instance-data/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
		REGION=$(curl --silent -H "X-aws-ec2-metadata-token: $TOKEN" http://instance-data/latest/meta-data/placement/availability-zone | sed 's/.$//')
	fi

	echo ${REGION}
}

_aws_get_instance_id() {
	INSTANCE_ID=$(curl --silent http://instance-data/latest/meta-data/instance-id)
	if [ "" = "${INSTANCE_ID}" ]; then
		# Metadata v2
		TOKEN=$(curl --silent -X PUT "http://instance-data/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
		INSTANCE_ID=$(curl --silent -H "X-aws-ec2-metadata-token: $TOKEN" http://instance-data/latest/meta-data/instance-id)
	fi

	echo ${INSTANCE_ID}
}

_download_compose_aws() {
	REGION=$(_aws_get_region)
	INSTANCE_ID=$(_aws_get_instance_id)
	REMOTE_COMPOSE_YAML=$(aws ec2 describe-tags --region=${REGION} --filters "Name=resource-id,Values=${INSTANCE_ID}" | jq '.Tags[]|select(.Key=="startup-compose-file")|.Value' 2>/dev/null | tr -d '"' 2>/dev/null)

	if [ $? = 0 ] && [ -n "${REMOTE_COMPOSE_YAML}" ]; then
		PROTO=$(echo ${REMOTE_COMPOSE_YAML} | cut -c1-5)
		echo -n "Downloading remote sysctl from: ${REMOTE_COMPOSE_YAML}..."
		if [ "s3://" = "${PROTO}" ]; then
			aws s3 cp ${REMOTE_COMPOSE_YAML} /root/init/docker-compose.yml >/dev/null 2>&1
			echo "Done"
		else
			echo "Failed: Unable to get external file"
			exit 1
		fi
	fi
}

_download_sysctl_aws() {
	REGION=$(_aws_get_region)
	INSTANCE_ID=$(_aws_get_instance_id)
	REMOTE_SYSCTL_YAML=$(aws ec2 describe-tags --region=${REGION} --filters "Name=resource-id,Values=${INSTANCE_ID}" | jq '.Tags[]|select(.Key=="startup-sysctl-file")|.Value' 2>/dev/null | tr -d '"' 2>/dev/null)

	if [ $? = 0 ] && [ -n "${REMOTE_SYSCTL_YAML}" ]; then
		PROTO=$(echo ${REMOTE_SYSCTL_YAML} | cut -c1-5)
		echo -n "Downloading remote docker compose from: ${REMOTE_SYSCTL_YAML}..."
		if [ "s3://" = "${PROTO}" ]; then
			aws s3 cp ${REMOTE_SYSCTL_YAML} /etc/sysctl.conf
			echo "Done"
		else
			echo "Failed: Unable to get external file"
			exit 1
		fi
	fi

}

_docker_compose() {
	${DOCKER_COMPOSE_BIN} $@ 2>&1 | tee /tmp/dc_pull_stderr.txt

	# Fix docker-compose -> gcloud integration
	if [ $? -ne 0 ]; then
		SSL_ERROR=$(cat /tmp/dc_pull_stderr.txt | grep -c OPENSSL_1_1_1)
		if [ ${SSL_ERROR} -gt 0 ]; then
			echo "(OPS!: Found OPENSSL_1_1_1 error: fixing...)"
			export LD_LIBRARY_PATH=/usr/local/lib
			${DOCKER_COMPOSE_BIN} $@
		fi
	fi
}

_pre_init() {
	if [ -e /root/init/pre-init.sh ]; then
		echo "Executing pre-init script..."
		/root/init/pre-init.sh
	fi
}

#################################
# Starts
#################################

cd /root/init
echo $(date): start $0 "$@"
_lock

_wait_for_network
export HOSTNAME=$(hostname)

_pre_init

# Needs to be bootstraped?
if [ ! -e ${BOOTSTRAP_FILE} ]; then
	_bootstrap
else
	_apply_fixes
fi

# Wait for docker-engine
while [ ! -e ${DOCKER_SOCK} ]; do
	sleep 1
done

# Update
if [ ${UPDATE} -gt 0 ]; then
	echo -n "Updating init.sh...."
	STATUS=$(curl -s -o /root/init/.init.sh -w '%{http_code}' ${UPDATE_URL})
	VALID=$(grep -c "UPDATE_URL" /root/init/.init.sh)

	if [ ${STATUS} -eq 200 ] && [ ${VALID} -gt 0 ]; then
		echo "OK"
		cat /root/init/.init.sh >/root/init/init.sh
		rm -f /root/init/.init.sh
		chmod +x /root/init/init.sh

	else
		echo "ERROR: Some problem during download" ${STATUS}
	fi

	_unlock
	exit
fi

# We are running on AWS or not?
AWS=0

# Try instance metadata v1
curl --max-time 1 --fail -s http://instance-data/latest/meta-data/instance-id >/dev/null 2>&1 && AWS=1

# Try instance metadata v2
if [ ${AWS} -eq 0 ]; then
	curl --max-time 1 --fail -s -X PUT http://instance-data/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" >/dev/null 2>&1 && AWS=1
fi

# Force new config for docker (on google)
if [ ${AWS} -eq 0 ] && [ $(which gcloud) ]; then
	echo -n "Refreshing GOOGLE docker auth..."
	rm -f /root/.dockercfg >/dev/null 2>&1 || /bin/true
	gcloud docker ps >/dev/null 2>&1 || /bin/true
	gcloud docker --authorize-only >/dev/null 2>&1 || /bin/true
	gcloud auth configure-docker --quiet >/dev/null 2>&1 || /bin/true
	echo "done"
fi

# Force new config for docker (on aws)
if [ ${AWS} -eq 1 ] && [ $(which aws) ]; then
	echo -n "Refreshing AWS docker auth..."
	REGION=$(_aws_get_region)

	# AWSCLI v2
	if [ $(aws --version | grep 'aws-cli/2' -c) -gt 0 ]; then
		ACCOUNT=$(aws sts get-caller-identity | jq .Account -r)
		aws ecr get-login-password | docker login --username AWS --password-stdin ${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com >/dev/null 2>&1

	else
		$(aws ecr get-login --region ${REGION} | sed "s/-e none//g") >/dev/null 2>&1
	fi

	echo "done"
fi

# Donwload remote compose file and wait for it
if [ ${PULL} -gt 0 ] && [ ${AWS} -eq 0 ]; then
	_download_sysctl_gcp
	_download_compose_gcp

elif [ ${PULL} -gt 0 ]; then
	_download_sysctl_aws
	_download_compose_aws
fi

if [ ! -f docker-compose.yml ]; then
	echo "Unable to find docker-compose.yml file"
	exit 1
fi

# STOP: Kill'em all
if [ ${STOP} -gt 0 ]; then
	_docker_compose stop
	_docker_compose kill
	_docker_compose rm -f

	# Double check
	pending=$($DOCKER_BIN ps --no-trunc -aq)
	[ "x$pending" != "x" ] && ${DOCKER_BIN} rm -f $pending
fi

# PULL: Refresh local images
if [ ${PULL} -gt 0 ]; then
	echo -n "Refreshing local images..."
	_docker_compose pull
	echo "done"
fi

# BUILD: Build containers
if [ ${BUILD} -gt 0 ]; then
	echo -n "Building containers..."
	_docker_compose build
	echo "done"
fi

# START: Start containers
if [ ${START} -gt 0 ]; then
	FORCE_RECREATE=""
	[ ${RECREATE} -gt 0 ] && FORCE_RECREATE="--force-recreate"
	_docker_compose up -d --remove-orphans ${FORCE_RECREATE}
fi

# CLEAN: Cleanup build images
if [ $CLEAN -gt 0 ]; then
	echo -n "Deleting unused images..."
	_clean_images
	echo "done"
	echo -n "Docker system prune..."
	docker system prune -af >/dev/null 2>&1 || true
	echo "done"
fi

_unlock
