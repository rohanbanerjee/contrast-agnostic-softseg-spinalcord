#!/bin/bash
#
# Process data. Note. Input data are already resample and reoriented to RPI.
#
# Usage:
#   ./process_data.sh <SUBJECT>
#
# Manual segmentations or labels should be located under:
# PATH_DATA/derivatives/labels/SUBJECT/anat/
#
# Authors: Sandrine Bédard

# The following global variables are retrieved from the caller sct_run_batch
# but could be overwritten by uncommenting the lines below:
# PATH_DATA_PROCESSED="~/data_processed"
# PATH_RESULTS="~/results"
# PATH_LOG="~/log"
# PATH_QC="~/qc"

set -x
# Immediately exit if error
set -e -o pipefail

# Exit if user presses CTRL+C (Linux) or CMD+C (OSX)
trap "echo Caught Keyboard Interrupt within script. Exiting now.; exit" INT

# Retrieve input params
SUBJECT=$1

# get starting time:
start=`date +%s`

# Display useful info for the log, such as SCT version, RAM and CPU cores available
sct_check_dependencies -short

# Go to folder where data will be copied and processed
cd ${PATH_DATA_PROCESSED}
# Copy list of participants in processed data folder
if [[ ! -f "participants.tsv" ]]; then
  rsync -avzh $PATH_DATA/participants.tsv .
fi
# Copy list of participants in resutls folder
if [[ ! -f $PATH_RESULTS/"participants.tsv" ]]; then
  rsync -avzh $PATH_DATA/participants.tsv $PATH_RESULTS/"participants.tsv"
fi
# Copy source images
rsync -avzh $PATH_DATA/$SUBJECT .
# Go to anat folder where all structural data are located
cd ${SUBJECT}/anat/

# FUNCTIONS
# ==============================================================================

segment_if_does_not_exist(){
  local file="$1"
  local contrast="$2"
  # Find contrast
  if [[ $contrast == "dwi" ]]; then
    folder_contrast="dwi"
  else
    folder_contrast="anat"
  fi

  # Update global variable with segmentation file name
  FILESEG="${file}_seg"
  FILESEGMANUAL="${PATH_DATA}/derivatives/labels/${SUBJECT}/${folder_contrast}/${FILESEG}-manual.nii.gz"
  echo
  echo "Looking for manual segmentation: $FILESEGMANUAL"
  if [[ -e $FILESEGMANUAL ]]; then
    echo "Found! Using manual segmentation."
    rsync -avzh $FILESEGMANUAL ${FILESEG}.nii.gz
    sct_qc -i ${file}.nii.gz -s ${FILESEG}.nii.gz -p sct_deepseg_sc -qc ${PATH_QC} -qc-subject ${SUBJECT}
  else
    echo "Not found. Proceeding with automatic segmentation."
    # Segment spinal cord
    sct_deepseg_sc -i ${file}.nii.gz -c $contrast -qc ${PATH_QC} -qc-subject ${SUBJECT}
  fi
}

# T1w
# ------------------------------------------------------------------------------
file_t1="${SUBJECT}_T1w"

# Segment spinal cord (only if it does not exist)
segment_if_does_not_exist $file_t1 "t1"
file_t1_seg=$FILESEG

# T2w
# ------------------------------------------------------------------------------
file_t2="${SUBJECT}_T2w"

# Segment spinal cord (only if it does not exist)
segment_if_does_not_exist $file_t2 "t2"
file_t2_seg=$FILESEG

# T2s
# ------------------------------------------------------------------------------
file_t2s="${SUBJECT}_T2star"

# Segment spinal cord (only if it does not exist)
segment_if_does_not_exist $file_t2s "t2s" 
file_t2s_seg=$FILESEG

# MTS
# ------------------------------------------------------------------------------
file_t1w="${SUBJECT}_acq-T1w_MTS"
file_mton="${SUBJECT}_acq-MTon_MTS"

# Segment spinal cord (only if it does not exist)
segment_if_does_not_exist $file_t1w "t1" 
file_t1w_seg=$FILESEG
segment_if_does_not_exist $file_mton "t2s"
file_mton_seg=$FILESEG


# DWI
# ------------------------------------------------------------------------------
cd ../dwi
file_dwi_mean="${SUBJECT}_rec-average_dwi"

# Segment spinal cord (only if it does not exist)
segment_if_does_not_exist ${file_dwi_mean} "dwi"

# Go back to parent folder
cd ../anat

# Registration
# ------------------------------------------------------------------------------
# Create mask
file_t2_mask="${file_t2_seg}_mask"
sct_create_mask -i ${file_t2}.nii.gz -p centerline,${file_t2_seg}.nii.gz -size 55mm -o ${file_t2_mask}.nii.gz

# Register T1w to T2w
sct_register_multimodal -i ${file_t1}.nii.gz -d ${file_t2}.nii.gz -iseg ${file_t1_seg}.nii.gz -dseg ${file_t2_seg}.nii.gz -m ${file_t2_mask}.nii.gz -param step=1,type=im,algo=slicereg,slicewise=1,metric=CC,iter=10,shrink=4,poly=2:step=2,type=im,algo=slicereg,slicewise=1,metric=CC,iter=10,shrink=2 -qc ${PATH_QC} -qc-subject ${SUBJECT}
# Regeister T2s to T2
sct_register_multimodal -i ${file_t2s}.nii.gz -d ${file_t2}.nii.gz -iseg ${file_t2s_seg}.nii.gz -dseg ${file_t2_seg}.nii.gz -m ${file_t2_mask}.nii.gz -param step=1,type=im,algo=slicereg,slicewise=1,metric=CC,iter=10,shrink=4:step=2,type=im,algo=slicereg,slicewise=1,metric=CC,iter=10,shrink=2 -qc ${PATH_QC} -qc-subject ${SUBJECT}

# TODO: remove -x spline to test
# TODO: test poly=2 or other

# SC Segmentation of registered images
# ------------------------------------------------------------------------------

# Either run sct_deepseg again or sct_apply_transfo --> binarize after or apply with -x nn

# T1w segmentation
sct_deepseg_sc -i ${file_t1}_reg.nii.gz -c t1 -qc ${PATH_QC} -qc-subject ${SUBJECT}
file_t1_seg="${file_t1}_reg_seg"
# T2s segmentation _T2star2sub-amu01_T2w | Try segmentation on T2s_reg but in T2s space
# sct_apply_transfo -i ${file_t2s_seg}.nii.gz -d ${file_t2_seg}.nii.gz -w warp_${file_t2s}2${file_t2}.nii.gz
sct_deepseg_sc -i ${file_t2s}_reg.nii.gz -c t2s -qc ${PATH_QC} -qc-subject ${SUBJECT}
file_t2s_seg="${file_t2s}_reg_seg"


# Extra Registration
# ------------------------------------------------------------------------------
# Register MTon and T1w_MT to T2 | TODO: continue to tweek parameters
sct_register_multimodal -i ${file_t1w}.nii.gz -d ${file_t2}.nii.gz -iseg ${file_t1w_seg}.nii.gz -dseg ${file_t2_seg}.nii.gz -m ${file_t2_mask}.nii.gz -param step=1,type=im,algo=slicereg,slicewise=1,metric=CC,iter=10,shrink=4:step=2,type=im,algo=slicereg,slicewise=1,metric=CC,iter=10,shrink=2 -qc ${PATH_QC} -qc-subject ${SUBJECT}
sct_register_multimodal -i ${file_mton}.nii.gz -d ${file_t2}.nii.gz -iseg ${file_mton_seg}.nii.gz -dseg ${file_t2_seg}.nii.gz -m ${file_t2_mask}.nii.gz -param step=1,type=im,algo=slicereg,slicewise=1,metric=CC,iter=10,shrink=4:step=2,type=im,algo=slicereg,slicewise=1,metric=CC,iter=10,shrink=2 -qc ${PATH_QC} -qc-subject ${SUBJECT}


# Create soft SC segmentation
# ------------------------------------------------------------------------------
# TODO: find a way that on the slices where T2 star is not, to have only 2 values
sct_image -i ${file_t2_seg}.nii.gz ${file_t1_seg}.nii.gz  ${file_t2s_seg}.nii.gz -concat t -o tmp.concat.nii.gz
sct_maths -i tmp.concat.nii.gz -mean t -o ${file_t2}_seg_mean.nii.gz

file_softseg="${file_t2}_seg_mean"

sct_qc -i ${file_t1}_reg.nii.gz -s ${file_softseg}.nii.gz -p sct_deepseg_sc -qc ${PATH_QC} -qc-subject ${SUBJECT}
sct_qc -i ${file_t2}.nii.gz -s ${file_softseg}.nii.gz -p sct_deepseg_sc -qc ${PATH_QC} -qc-subject ${SUBJECT}

# Register softseg to T2s_reg
sct_register_multimodal -i ${file_softseg}.nii.gz -d ${file_t2s}_reg_seg.nii.gz -identity 1 -x nn
sct_qc -i ${file_t2s}.nii.gz -s ${file_softseg}_reg.nii.gz -p sct_deepseg_sc -qc ${PATH_QC} -qc-subject ${SUBJECT}



# Display useful info for the log
end=`date +%s`
runtime=$((end-start))
echo
echo "~~~"
echo "SCT version: `sct_version`"
echo "Ran on:      `uname -nsr`"
echo "Duration:    $(($runtime / 3600))hrs $((($runtime / 60) % 60))min $(($runtime % 60))sec"
echo "~~~"
