#!/bin/bash

# Training and prediction for the Bird audio detection challenge 2017
# Thomas Grill <thomas.grill@ofai.at>
#
# Training: 8 GiB RAM, 4 GiB GPU RAM
# Evaluation: 8 GiB RAM, 2 GiB GPU RAM


here="${0%/*}"

. "$here/config.inc"

# import network/learning configuration
. "$here/network_${NETWORK}.inc"

LISTPATH="$WORKPATH/filelists"
SPECTPATH="$WORKPATH/spect"


# locations of prediction files
first_predictions="$WORKPATH/prediction_first.csv"
final_predictions="$WORKPATH/prediction_final.csv"


#############################
# define training
#############################
function train_model {
    model="$1"  # model including path
    filelists="$2"  # file list to use
    seed="$3"
    cmdargs="${@:4}"

    echo "Computing model ${model} with network ${NETWORK}."

    "$here/code/simplenn_main.py" \
    --mode=train \
    --problem=binary \
    --var measures= \
    --inputs filelist:filelist \
    --var filelist:path="$LISTPATH" \
    --var filelist:lists="${filelists}" \
    --process "filelistshuffle:shuffle(seed=$seed,memory=25000)" \
    --process "input:${here}/code/load_data.py(type=spect,downmix=0,cycle=0,denoise=1,width=${net_width},seed=$seed)" \
    --var input:labels="${LABELPATH}"/'*.csv' \
    --var input:data="${SPECTPATH}/%(id)s.h5" \
    --var input:data_vars=1k \
    --process collect:collect \
    --var "collect:source=0..1"  \
    --process "scale@1:range(out_min=0.01,out_max=0.99)" \
    --layers "${net_layers}" \
    --save "${model}.h5" \
    ${net_options} \
    ${cmdargs}
}

#############################
# define evaluation
#############################
function evaluate_model {
    model="$1"  # model including path
    filelists="$2"  # file list to use
    predictions="$3"  # model including path
    cmdargs="${@:4}" # extra arguments

    echo "Evaluating model ${model}."

    "$here/code/simplenn_main.py" \
    --mode=evaluate \
    --var input:labels="${LABELPATH}"/'*.csv' \
    --var input:data="${SPECTPATH}/%(id)s.h5" \
    --var filelist:path="$LISTPATH" \
    --var filelist:lists=$filelists \
    --var filelistshuffle:bypass=1 \
    --var augment:bypass=1 \
    --load "${model}.h5" \
    --save "${predictions}.h5" \
    ${cmdargs}
}


#####################################
# prepare file lists and spectrograms
#####################################
function stage1_prepare {
    echo "Preparing file lists."
    mkdir $LISTPATH 2> /dev/null
    "$here/code/create_filelists.py" "$LABELPATH" $TRAIN > "$LISTPATH/train"
    "$here/code/create_filelists.py" "$LABELPATH" $TEST > "$LISTPATH/test"

    echo "Preparing spectrograms."
    mkdir $SPECTPATH 2> /dev/null
    "$here/code/prepare_spectrograms.sh" "${AUDIOPATH}" "${SPECTPATH}"
}

#############################
# first training run
#############################
function stage1_train {
    echo "First training stage."

    # process model and fold indices
    if [ "$1" != "" -a  "${1:0:1}" != '-' ]; then
        # index is given as first argument
        idxs="$1"
        cmdargs="${@:2}"
    else
        idxs=`seq ${model_count}`
        cmdargs="${@:1}"
    fi

    for i in ${idxs}; do
        model="$WORKPATH/model_first_${i}"
        if [ ! -f "${model}.h5" ]; then # check for existence
            echo "Training model ${model}."
            res=$(train_model "${model}" train ${i} ${cmdargs})
            if [ ${res} -ne 0 ]; then return ${res}; fi
            echo "Done training model ${model}."
        else
            echo "Using existing model ${model}."
        fi
    done
}

#############################
# first prediction run
#############################
function stage1_predict {
    echo "Computing first stage predictions."

    cmdargs="${@:1}"    
    for i in `seq ${model_count}`; do
        model="$WORKPATH/model_first_${i}"
        prediction="${model}.prediction"
        if [ ! -f "${prediction}.h5" ]; then # check for existence
            res=$(evaluate_model "${model}" test "${prediction}" ${cmdargs})
            if [ ${res} -ne 0 ]; then return ${res}; fi
        else
            echo "Using existing predictions ${prediction}."
        fi
    done
    
    # prediction by bagging
    echo "Bagging first stage predictions."
    "$here/code/predict.py" "$WORKPATH"/model_first_?.prediction.h5 --filelist "$LABELPATH/$TEST.csv" --filelist-header --out "$first_predictions" --out-header
    echo "Done. First stage predictions are in ${first_predictions}."
}

#############################
# compute pseudo_labels
#############################
function stage2_prepare {
    echo "Prepare second stage by analyzing first stage."
    
    # filter list by threshold
    # split in half randomly
    "$here/code/make_pseudo.py" --filelist "$first_predictions" --filelist-header --threshold=${pseudo_threshold} --folds=${pseudo_folds} --out "$LISTPATH/test_pseudo_%(fold)i" --out-prefix="$TEST/" --out-suffix='.wav' 

    # merge train filelist and half pseudo filelists
    for h in `seq ${pseudo_folds}`; do
        cat "$LISTPATH/train" "$LISTPATH/test_pseudo_${h}" > "$LISTPATH/train_pseudo_${h}"
    done
    echo "Prepared file lists for second stage."
}

#############################
# second run
#############################
function stage2_train {
    echo "Second training stage."
    
    # process model and fold indices
    if [ "$1" != "" -a "${1:0:1}" != '-' ]; then
        # index is given as first argument
        idxs="$1"
        if [ "$2" != "" -a "${2:0:1}" != '-' ]; then
            # index is given as second argument
            folds="$2"
            cmdargs="${@:3}"
        else
            folds=`seq ${pseudo_folds}`
            cmdargs="${@:2}"
        fi
    else
        idxs=`seq ${model_count}`
        folds=`seq ${pseudo_folds}`
        cmdargs="${@:1}"
    fi
    
    for i in $idxs; do
        for h in $folds; do
            model="$WORKPATH/model_second_${i}_${h}"
            if [ ! -f "${model}.h5" ]; then # check for existence
                echo "Training model ${model}."
                res=$(train_model "${model}" "train_pseudo_${h}" ${i} ${cmdargs})
                if [ ${res} -ne 0 ]; then return ${res}; fi
                echo "Done training model ${model}."
            else
                echo "Using existing model ${model}."
            fi
        done
    done
}

#############################################
# prediction by bagging all available models
############################################
function stage2_predict {
    echo "Computing final predictions."
    
    cmdargs="${@:1}"
    for i in `seq ${model_count}`; do
        for h in `seq ${pseudo_folds}`; do
            model="$WORKPATH/model_second_${i}_${h}"
            prediction="${model}.prediction"
            if [ ! -f "${prediction}.h5" ]; then # check for existence
                res=$(evaluate_model "${model}" test "${prediction}" ${cmdargs})
                if [ ${res} -ne 0 ]; then return ${res}; fi
            else
                echo "Using existing predictions ${prediction}."
            fi
        done
    done

    echo "Bagging final predictions."
    "$here/code/predict.py" "$WORKPATH"/model_*.prediction.h5 --filelist "$LABELPATH/$TEST.csv" --filelist-header --out "$final_predictions" --out-header
    echo "Done. Final predictions are in ${final_predictions}."
}

###################################################################

if [ "$1" == 'help' -o "$1" == '-help' -o "$1" == '--help' ]; then
    echo "Proposal for Bird audio detection challenge 2017"
    echo "by Thomas Grill <thomas.grill@ofai.at>"
    echo ""
    echo "Without any arguments, the full two-stage train/predict sequence is run"
    echo "Subtasks can be run by specifying one of: stage1_prepare, stage1_train, stage1_predict, stage2_prepare, stage2_train, stage2_predict"
    
elif [ "$1" == "" -o "${1:0:1}" == '-' ]; then
    echo "Running full two-stage train/predict sequence"
    cmdargs="${@:1}"
    stage1_prepare ${cmdargs} && stage1_train ${cmdargs} && stage1_predict ${cmdargs} && stage2_prepare ${cmdargs} && stage2_train ${cmdargs} && stage2_predict ${cmdargs} 
else
    echo "Running sub-task $1"
    ${@:1}
fi
