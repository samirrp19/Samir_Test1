pipeline {
    agent any

    stages {

        stage('Checkout') {
            steps {
                echo '📥 Checking out source code from repository'
            }
        }

        stage('Build') {
            steps {
                echo '🔨 Building the application'
                echo 'Build completed successfully'
            }
        }

        stage('Unit Test') {
            steps {
                echo '🧪 Running unit tests'
                echo 'All unit tests passed'
            }
        }

        stage('Code Quality') {
            steps {
                echo '🔍 Performing code quality analysis'
                echo 'No critical issues found'
            }
        }

        stage('Package') {
            steps {
                echo '📦 Packaging the application'
                echo 'Artifact created successfully'
            }
        }

        stage('Deploy') {
            steps {
                echo '🚀 Deploying application to environment'
                echo 'Deployment successful'
            }
        }
    }

    post {
        success {
            echo '✅ Pipeline completed successfully'
        }
        failure {
            echo '❌ Pipeline failed'
        }
        always {
            echo 'ℹ️ Pipeline execution finished'
        }
    }
}
