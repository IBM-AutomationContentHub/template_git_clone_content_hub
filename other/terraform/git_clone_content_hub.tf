#################################################################
# Terraform template that will clone all the repositories in the
# following org in github.com, to the Bring-Your-Own-Node (BYON):
#   * IBM-AutomationContentHub
#   * IBM-CAMHub-Open
#
# Version: 1.0
#
# =================================================================
# Licensed Materials - Property of IBM
# 5737-E67
# @ Copyright IBM Corporation 2016, 2017 All Rights Reserved
# US Government Users Restricted Rights - Use, duplication or disclosure
# restricted by GSA ADP Schedule Contract with IBM Corp.
# =================================================================

#########################################################
# Define the variables
#########################################################
variable "ip_address" {
  description = "IP address of the virtual machine to clone repositories to"
}

variable "user" {
  description = "User name to access the virtual machine"
}

variable "user_password" {
  description = "User password to access the virtual machine"
}

variable "github_token" {
  description = "Token used to access Github API to clone repositories"
}

#########################################################
# Execute in BYON
#########################################################
resource "null_resource" "clone_git" {
  # Specify the ssh connection
  connection {
    user     = "${var.user}"
    password = "${var.user_password}"
    host     = "${var.ip_address}"
  }

  # Create the installation script
  provisioner "file" {
    content = <<EOF
#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

GITHUB_TOKEN=$1

# Install git and curl
[ -f /usr/bin/yum ] && sudo yum install git curl -y -q
[ -f /usr/bin/apt-get ] && sudo apt-get install git curl -y -q

# Clone IBM-AutomationContentHub
bash clonegit.sh --org IBM-AutomationContentHub --token $GITHUB_TOKEN --host github.com --refresh --private

# Clone IBM-CAMHub-Open
bash clonegit.sh --org IBM-CAMHub-Open --token $GITHUB_TOKEN --host github.com --refresh --private

# Clean
rm -f clonegit.sh
history -c

EOF

    destination = "installation.sh"
  }

  # Create the clonegit script
  provisioner "file" {
    content = <<EOF
#!/usr/bin/env bash

function usage()
{
	echo "$0 --org git-org --token api-token --host GITHUB_HOST --public|--private"
	exit
}
if [ -z "$2" ] ; then
	usage
fi

GITHUB_HOST="github.com"
GIT_PATH="."
FORCE=false
REFRESH=false
grepString="false"

if [[ $# = "2" ]] && [[ "$1" = "--org" ]] && [[ -e ".launch-docker-compose.sh" ]] ; then
	# This is a refresh call, use the previous calls parameters
	token=`egrep "\-\-ibm_contenthub_git_access_token" .launch-docker-compose.sh | cut -f2 -d'='`
	GITHUB_HOST=`egrep "\-\-ibm_contenthub_git_host" .launch-docker-compose.sh | cut -f2 -d'='`
	[[ $1 =~ ^-o|--org$ ]] && { org="$2" ; shift 2; };
	REFRESH=true
	grepString="true|false"
else
	while test $# -gt 0; do
		[[ $1 =~ ^-h|--host$ ]] && { GITHUB_HOST="$2"; shift 2; continue; };
		[[ $1 =~ ^-o|--org$ ]] && { org="$2" ; shift 2; continue; };
		[[ $1 =~ ^-t|--token$ ]] && { token="$2"; shift 2; continue; };
		[[ $1 =~ ^-b|--branch$ ]] && { CLONE_BRANCH="--branch $2"; shift 2; continue; };
		[[ $1 =~ ^-p|--private$ ]] && { grepString="true|false"; shift ; continue; };
		[[ $1 =~ ^-db|--defaultbranch$ ]] && { GET_DEFAULT="true"; shift ; continue; };
		[[ $1 =~ ^-d|--debug$ ]] && { set -x ; shift; continue; };
		[[ $1 =~ ^-g|--gitpath$ ]] && { GIT_PATH="$2"; shift 2 ; continue; };
		[[ $1 =~ ^-f|--force$ ]] && { FORCE=true ; shift; continue; };
		[[ $1 =~ ^-r|--refresh$ ]] && { REFRESH=true ; shift; continue; };
		shift
	done
fi

[[ -z $token || -z org ]] && { echo "Must specify org and token" ; exit 1; }

# These should form the URL for pulling down all the repo information
httpgit=https://api.$GITHUB_HOST/
github=orgs/$org/
repos=repos
access_token="access_token=$token"

fullurl="$httpgit$github$repos?$access_token&per_page=100&page="

wc=0
wclast=1
page=1
rm -f repo.list
while test $wc -ne $wclast
do
	curl -s $fullurl$page | egrep '"full_name":|"private":' | cut -f2 -d: | rev | cut -c2- | rev | tr -d '"'  >> repo.list
	let 'page=page+1'
	wclast=$wc
	wc=`cat repo.list | wc -l`
done

[[ ! -s "repo.list" ]] && { echo "Could not find any repositories to clone. Continue with deployment" ; exit 0 ; }

errorcount=0

set $(cat repo.list)

while test $# -gt "0"
do
	if [ "$1" = "IBM-AutomationContentHub/advanced_content_runtime_chef" ] ; then
		shift 2;
		continue;
	fi
	echo $2 | egrep "$grepString" > /dev/null
	if [ $? = "0" ] ; then
		# This record should be processed
		reponame=`echo $1 | cut -f4 -d'"'`
		if [ $FORCE = true ] ; then
			rm -rf $1
		fi
		if [ $REFRESH = true ] && [ -e $1 ] ; then
			git --git-dir=$1/.git pull
		else
			git clone -q $CLONE_BRANCH https://$token@$GITHUB_HOST/$1 $1
			if [ $? = "0" ] ; then
				# The clone work
				echo clone : $1 successful
			else
				if [ -z "$CLONE_BRANCH" ] ; then
					echo FAILED clone : $1
					let 'errorcount=errorcount+1'
					if [ $errorcount = "1" ] ; then
						# There is a problem with the git connection, terminate
						echo -e "\n\n\nWARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING"
						echo "WARNING: Could not complete the clone of the git repos."
						echo "Execute the command : ./clonegit.sh --org $org"
						echo -e "WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING\n\n\n"
						exit 0
					fi
				else
					if [ "$GET_DEFAULT" = "true" ] ; then
						git clone -q https://$token@$GITHUB_HOST/$1 $1
						if [ $? = "0" ] ; then
							# The clone work
							echo clone : $1 successful
						else
							echo FAILED clone : $1
						fi
					else
						echo FAILED clone : $1
					fi
				fi
			fi
		fi
	else
		echo Skipping : $1
	fi
	shift; shift;
done
rm -f repo.list

EOF

    destination = "clonegit.sh"
  }

  # Execute the script remotely
  provisioner "remote-exec" {
    inline = [
      "bash installation.sh \"${var.github_token}\"; rm -f installation.sh",
    ]
  }
}
