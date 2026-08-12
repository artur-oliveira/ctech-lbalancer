import * as cdk from 'aws-cdk-lib';
import * as s3 from 'aws-cdk-lib/aws-s3';
import {Construct} from 'constructs';
import {HAPROXY_ARTIFACT_BUCKET_NAME} from './constants';

/**
 * Account/region-wide, content-addressed HAProxy artifacts shared by every
 * environment. S3 has no fixed bucket charge and this retained bucket avoids
 * the shared deployments bucket's 30-day expiration policy.
 */
export class ArtifactStack extends cdk.Stack {
  public readonly bucket: s3.Bucket;

  constructor(scope: Construct, id: string, props: cdk.StackProps) {
    super(scope, id, props);

    this.bucket = new s3.Bucket(this, 'Bucket', {
      bucketName: HAPROXY_ARTIFACT_BUCKET_NAME,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      removalPolicy: cdk.RemovalPolicy.RETAIN,
    });

    new cdk.CfnOutput(this, 'BucketName', {value: this.bucket.bucketName});
  }
}
