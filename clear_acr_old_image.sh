#!/bin/bash

#Date: 2024/10/23
#Author: Alex Xiong
#Mail: 
#Function: This script is used to keep the latest 30 images in each repo and delete all other old images
#Version: V 1.0

REGISTRY=testacr;
LOGFILE=./clearoldimagesfromacr.log;
REPOPREFIX="test_repo"
TAGPREFIX="test_tag"
LEFTCOUNT=30

# Create a log file for this script
touch ${LOGFILE}

echo "Start to run the script at $(date)" >> ${LOGFILE}

#Precheck before running the script
which jq &> /dev/null || echo "jq is not installed on your machine, please install it" 
which az &> /dev/null || echo "az is not installed on your machine, please install it"

# Login  ACR
az login --identity &>> ${LOGFILE} && echo "az Login succeed" || { echo "az login failed"; exit 1; };
az acr login -n ${REGISTRY} &>> ${LOGFILE} && echo "az acr Login succeed" || { echo "az acr login failed"; exit 1; };


function untag_old_image {
  # List all the tags will be deleted
  TO_BE_UNTAG_LIST=$(az acr repository show-manifests -n ${REGISTRY} --repository ${REPOSITORY} --orderby time_desc 2>> ${LOGFILE} | jq -r ".[].tags[] | select(startswith(\"${TAGPREFIX}\"))" | awk "NR > ${LEFTCOUNT}");
  echo "To be deleted tags are ${TO_BE_UNTAG_LIST}" >> ${LOGFILE}

  # Delete the old images
  echo "start to untag the image base on the above sequence" >>  ${LOGFILE}
  for UNTAGGING_IMG in ${TO_BE_UNTAG_LIST}; do { az acr repository untag --name ${REGISTRY} --image ${REPOSITORY}:${UNTAGGING_IMG} &>> ${LOGFILE}; echo "Untag ${UNTAGGING_IMG} successfully" >> ${LOGFILE}; } || { echo "Failed to untag ${UNTAGGING_IMG}" >> ${LOGFILE}; exit 1; }; sleep 5; done;
}

function del_untaged_image {
  TO_BE_DELETED_MANI=$(az acr repository show-manifests -n ${REGISTRY} --repository ${REPOSITORY} 2> /dev/null | jq -r '.[] | select(.tags | length == 0) | .digest')
  
  echo "start to delete the image without the tags" >>  ${LOGFILE}
  for DELETING_IMG_MANI in ${TO_BE_DELETED_MANI}; do { az acr repository delete --name ${REGISTRY} --image ${REPOSITORY}@${DELETING_IMG_MANI} --yes &>> ${LOGFILE}; echo "Delete ${DELETING_IMG_MANI} successfully" >> ${LOGFILE}; } || { echo "Failed to delete ${DELETING_IMG_MANI}" >> ${LOGFILE}; exit 1; }; sleep 5; done;
}


REPOSITORIES=$(az acr repository list --name ${REGISTRY} --output table | grep "^${REPOPREFIX}")

for REPOSITORY in ${REPOSITORIES}; 
do 
  echo "Start to clear old images in the ${REPOSITORY} Repo, Keep ${LEFTCOUNT} latest images" >>  ${LOGFILE};
  untag_old_image; 
  del_untaged_image; 
  echo "Clear old images successfully, Keep ${LEFTCOUNT} latest images in the ${REPOSITORY} Repo"; 
done
