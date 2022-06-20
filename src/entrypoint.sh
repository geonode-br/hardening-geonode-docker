#!/bin/bash

# Exit script in case of error
set -e

# exec all in the default virtualenv (edit .bashrc to enable alias in non-interactive mode)
source ${GEONODE_HOME}/venv/bin/activate

cmd="$@"

# subshell in GeoNode SRC
(
    cd ${GEONODE_HOME}/venv/src/${GEONODE_PROJECT_NAME}

    INVOKE_LOG_STDOUT=${INVOKE_LOG_STDOUT:-FALSE}
    INVOKE_LOG_FILE=/var/log/geonode-invoke.log

    invoke () {
        if [ $INVOKE_LOG_STDOUT = 'true' ] || [ $INVOKE_LOG_STDOUT = 'True' ]
        then
            ${GEONODE_HOME}/venv/bin/invoke $cmd
        else
            ${GEONODE_HOME}/venv/bin/invoke $cmd >> ${INVOKE_LOG_FILE} 2>&1
        fi
        echo "$cmd tasks done"
    }

    # Start cron && memcached services
    service cron restart
    service memcached restart

    echo $"\n\n\n"
    echo "-----------------------------------------------------"
    echo "STARTING DJANGO ENTRYPOINT $(date)"
    echo "-----------------------------------------------------"

    invoke update

    # Does nothing in non-interactive shell, like this entrypoint execution (L6-9)
    # source $HOME/.bashrc 
    source $HOME/.override_env

    echo DOCKER_API_VERSION=$DOCKER_API_VERSION
    echo POSTGRES_USER=$POSTGRES_USER
    echo POSTGRES_PASSWORD=$POSTGRES_PASSWORD
    echo DATABASE_URL=$DATABASE_URL
    echo GEODATABASE_URL=$GEODATABASE_URL
    echo SITEURL=$SITEURL
    echo ALLOWED_HOSTS=$ALLOWED_HOSTS
    echo GEOSERVER_PUBLIC_LOCATION=$GEOSERVER_PUBLIC_LOCATION
    echo MONITORING_ENABLED=$MONITORING_ENABLED
    echo MONITORING_HOST_NAME=$MONITORING_HOST_NAME
    echo MONITORING_SERVICE_NAME=$MONITORING_SERVICE_NAME
    echo MONITORING_DATA_TTL=$MONITORING_DATA_TTL

    invoke waitfordbs

    echo DOCKER_ENV=$DOCKER_ENV

    if [ -z ${DOCKER_ENV} ] || [ ${DOCKER_ENV} = "development" ]
    then

        invoke migrations
        invoke prepare
        invoke fixtures

        if [ ${IS_CELERY} = "true" ] || [ ${IS_CELERY} = "True" ]
        then

            echo "Executing Celery server $cmd for Development"

        else

            invoke devrequirements
            invoke statics

            echo "Executing standard Django server $cmd for Development"

        fi

    else
        if [ ${IS_CELERY} = "true" ]  || [ ${IS_CELERY} = "True" ]
        then
            echo "Executing Celery server $cmd for Production"
        else

            invoke migrations
            invoke prepare

            if [ ${FORCE_REINIT} = "true" ]  || [ ${FORCE_REINIT} = "True" ] || [ ! -e "/mnt/volumes/statics/geonode_init.lock" ]; then
                echo "LOG INIT" > ${INVOKE_LOG_FILE}
                invoke updategeoip
                invoke fixtures
                invoke monitoringfixture
                invoke initialized
                invoke updateadmin
            fi

            invoke statics
            invoke waitforgeoserver
            invoke geoserverfixture

            echo "Executing UWSGI server $cmd for Production"
        fi
    fi

)

echo "-----------------------------------------------------"
echo "FINISHED DJANGO ENTRYPOINT --------------------------"
echo "-----------------------------------------------------"

# Run the CMD 
echo "got command $cmd"
exec $cmd
