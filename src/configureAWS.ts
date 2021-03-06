import * as process from 'process';

import * as fs from 'fs';
import * as path from 'path';

const awsUserDir = process.env.HOME ? path.join(process.env.HOME as string, '.aws') : null;
if (awsUserDir && fs.existsSync(awsUserDir)) {
  // We also set this env-var in the main cli entry-point
  process.env.AWS_SDK_LOAD_CONFIG = '1'; // see https://github.com/aws/aws-sdk-js/pull/1391
  // Note:
  // if this is set and ~/.aws doesn't exist we run into issue #17 as soon as the sdk is loaded:
  //  Error: ENOENT: no such file or directory, open '.../.aws/credentials
}

const USE_AWS_CLI_STS_CACHE = process.env.iidy_use_sts_cache !== undefined;

import * as _ from 'lodash';
import * as aws from 'aws-sdk';

import {logger} from './logger';
import {AWSRegion} from './aws-regions';

function getCredentialsProviderChain(profile?: string) {
  const hasDotAWS = (awsUserDir && fs.existsSync(awsUserDir));
  if (profile) {
    if (profile.startsWith('arn:')) {
      throw new Error('profile was set to a role ARN. Use AssumeRoleArn instead');
    }
    if (!hasDotAWS) {
      throw new Error('AWS profile provided but ~/.aws/{config,credentials} not found.');
    }
    return new aws.CredentialProviderChain([() => new aws.SharedIniFileCredentials({profile})]);
  } else {
    return new aws.CredentialProviderChain();
  }
}

async function resolveCredentials(profile?: string, assumeRoleArn?: string) {
  if (assumeRoleArn) {
    const masterCreds = await getCredentialsProviderChain(profile).resolvePromise();
    const tempCreds = new aws.TemporaryCredentials({RoleArn: assumeRoleArn, RoleSessionName: 'iidy'}, masterCreds);
    await tempCreds.getPromise();
    aws.config.credentials = tempCreds;
  } else {
    // note, profile might be undefined here and that's fine.
    aws.config.credentials = await getCredentialsProviderChain(profile).resolvePromise();
    // TODO optionally cache the credentials here
  }
}

// TODO change to this interface
export interface AWSConfig {
  profile?: string;
  region?: AWSRegion;
  assumeRoleArn?: string;
}

async function configureAWS(config: AWSConfig) {
  const resolvedProfile: string | undefined = (
    config.profile || process.env.AWS_PROFILE || process.env.AWS_DEFAULT_PROFILE);
  await resolveCredentials(resolvedProfile, config.assumeRoleArn);

  const resolvedRegion = (
    config.region
    || process.env.AWS_REGION
    || process.env.AWS_DEFAULT_REGION);
  if (!_.isEmpty(resolvedRegion)) {
    logger.debug(`Setting AWS region: ${resolvedRegion}. aws.config.region was previously ${aws.config.region}`);
    aws.config.update({region: resolvedRegion});
  }
  aws.config.update({maxRetries: 10}); // default is undefined -> defaultRetryCount=3
  // the sdk will handle exponential backoff internally.
  // 1=100ms, 2=200ms, 3=400ms, 4=800ms, 5=1600ms,
  // 6=3200ms, 7=6400ms, 8=12800ms, 9=25600ms, 10=51200ms, 11=102400ms, 12=204800ms
}

export default configureAWS;
