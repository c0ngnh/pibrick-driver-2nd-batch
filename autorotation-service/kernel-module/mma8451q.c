// SPDX-License-Identifier: GPL-2.0
/*
 * piBrick MMA8451Q kernel module
 * Based on Bosch mma8452 driver, patched for piBrick hardware
 *
 * piBrick modifications:
 * - Support for pibrick,invert-x device tree property
 * - I2C address 0x1C (SA0 floating on piBrick)
 */

#include <linux/i2c.h>
#include <linux/iio/iio.h>
#include <linux/module.h>
#include <linux/mod_devicetable.h>
#include <linux/of.h>
#include <linux/of_device.h>
#include <linux/pm.h>
#include <linux/delay.h>

/* MMA8451Q registers */
#define MMA8451_STATUS		0x00
#define MMA8451_OUT_X_MSB	0x01
#define MMA8451_OUT_Y_MSB	0x03
#define MMA8451_OUT_Z_MSB	0x05
#define MMA8451_WHO_AM_I	0x0d
#define MMA8451_XYZ_DATA_CFG	0x0e
#define MMA8451_CTRL_REG1	0x2a

/* WHO_AM_I values */
#define MMA8451_WHOAMI_VAL	0x1a
#define MMA8452_WHOAMI_VAL	0x2a

/* STATUS register bits */
#define MMA8451_STATUS_ZYXDR	0x08

/* CTRL_REG1 bits */
#define MMA8451_CTRL_ACTIVE	0x01

struct mma8451q_data {
	struct i2c_client *client;
	struct mutex lock;
	bool invert_x;
};

static int mma8451q_set_active(struct i2c_client *client, bool active)
{
	int val = i2c_smbus_read_byte_data(client, MMA8451_CTRL_REG1);
	if (val < 0)
		return val;

	if (active)
		val |= MMA8451_CTRL_ACTIVE;
	else
		val &= ~MMA8451_CTRL_ACTIVE;

	return i2c_smbus_write_byte_data(client, MMA8451_CTRL_REG1, val);
}

static int mma8451q_read_raw(struct iio_dev *indio_dev,
			    struct iio_chan_spec const *chan,
			    int *val, int *val2, long mask)
{
	struct mma8451q_data *data = iio_priv(indio_dev);
	struct i2c_client *client = data->client;
	int ret;
	u8 buf[6];
	s16 raw;

	switch (mask) {
	case IIO_CHAN_INFO_RAW:
		break;
	default:
		return -EINVAL;
	}

	mutex_lock(&data->lock);

	ret = mma8451q_set_active(client, true);
	if (ret < 0)
		goto err_unlock;

	msleep(20);

	ret = i2c_smbus_read_byte_data(client, MMA8451_STATUS);
	if (ret < 0)
		goto err_unlock;
	if (!(ret & MMA8451_STATUS_ZYXDR)) {
		ret = -ENODATA;
		goto err_unlock;
	}

	ret = i2c_smbus_read_i2c_block_data(client, MMA8451_OUT_X_MSB, 6, buf);
	if (ret < 0)
		goto err_unlock;

	switch (chan->channel2) {
	case IIO_MOD_X:
		raw = be16_to_cpup((__be16 *)buf);
		*val = data->invert_x ? -raw : raw;
		break;
	case IIO_MOD_Y:
		raw = be16_to_cpup((__be16 *)(buf + 2));
		*val = raw;
		break;
	case IIO_MOD_Z:
		raw = be16_to_cpup((__be16 *)(buf + 4));
		*val = raw;
		break;
	default:
		ret = -EINVAL;
		goto err_unlock;
	}

	ret = IIO_VAL_INT;

err_unlock:
	mma8451q_set_active(client, false);
	mutex_unlock(&data->lock);

	return ret;
}

static const struct iio_chan_spec mma8451q_channels[] = {
	{
		.type = IIO_ACCEL,
		.modified = 1,
		.channel2 = IIO_MOD_X,
		.info_mask_separate = BIT(IIO_CHAN_INFO_RAW),
		.scan_index = 0,
		.scan_type = {
			.sign = 's',
			.realbits = 14,
			.storagebits = 16,
			.endianness = IIO_BE,
		},
	},
	{
		.type = IIO_ACCEL,
		.modified = 1,
		.channel2 = IIO_MOD_Y,
		.info_mask_separate = BIT(IIO_CHAN_INFO_RAW),
		.scan_index = 1,
		.scan_type = {
			.sign = 's',
			.realbits = 14,
			.storagebits = 16,
			.endianness = IIO_BE,
		},
	},
	{
		.type = IIO_ACCEL,
		.modified = 1,
		.channel2 = IIO_MOD_Z,
		.info_mask_separate = BIT(IIO_CHAN_INFO_RAW),
		.scan_index = 2,
		.scan_type = {
			.sign = 's',
			.realbits = 14,
			.storagebits = 16,
			.endianness = IIO_BE,
		},
	},
};

static const struct iio_info mma8451q_info = {
	.read_raw = mma8451q_read_raw,
};

static int mma8451q_probe(struct i2c_client *client)
{
	struct iio_dev *indio_dev;
	struct mma8451q_data *data;
	struct device_node *np = client->dev.of_node;
	int ret;

	indio_dev = devm_iio_device_alloc(&client->dev, sizeof(*data));
	if (!indio_dev)
		return -ENOMEM;

	data = iio_priv(indio_dev);
	data->client = client;
	mutex_init(&data->lock);

	data->invert_x = of_property_read_bool(np, "pibrick,invert-x");

	i2c_set_clientdata(client, indio_dev);
	indio_dev->name = "mma8451q";
	indio_dev->dev.parent = &client->dev;
	indio_dev->info = &mma8451q_info;
	indio_dev->modes = INDIO_DIRECT_MODE;
	indio_dev->channels = mma8451q_channels;
	indio_dev->num_channels = ARRAY_SIZE(mma8451q_channels);

	ret = i2c_smbus_read_byte_data(client, MMA8451_WHO_AM_I);
	if (ret < 0) {
		dev_err(&client->dev, "Error reading WHO_AM_I: %d\n", ret);
		return ret;
	}

	if (ret != MMA8451_WHOAMI_VAL && ret != MMA8452_WHOAMI_VAL)
		dev_warn(&client->dev, "Unexpected WHO_AM_I: 0x%02x\n", ret);

	dev_info(&client->dev, "MMA8451Q/Q2/Q3 (WHO_AM_I=0x%02x) invert_x=%d\n",
		 ret, data->invert_x);

	ret = i2c_smbus_write_byte_data(client, MMA8451_CTRL_REG1, 0);
	if (ret < 0)
		return ret;

	ret = i2c_smbus_write_byte_data(client, MMA8451_XYZ_DATA_CFG, 0);
	if (ret < 0)
		return ret;

	ret = iio_device_register(indio_dev);
	if (ret < 0)
		return ret;

	return 0;
}

static void mma8451q_remove(struct i2c_client *client)
{
	struct iio_dev *indio_dev = i2c_get_clientdata(client);
	iio_device_unregister(indio_dev);
	mma8451q_set_active(client, false);
}

static int mma8451q_suspend(struct device *dev)
{
	struct i2c_client *client = to_i2c_client(dev);
	return mma8451q_set_active(client, false);
}

static int mma8451q_resume(struct device *dev)
{
	struct i2c_client *client = to_i2c_client(dev);
	return mma8451q_set_active(client, true);
}

static SIMPLE_DEV_PM_OPS(mma8451q_pm_ops, mma8451q_suspend, mma8451q_resume);

static const struct of_device_id mma8451q_of_match[] = {
	{ .compatible = "pibrick,mma8451q", },
	{ .compatible = "fsl,mma8451q", },
	{ .compatible = "fsl,mma8451", },
	{ .compatible = "nxp,mma8451q", },
	{},
};
MODULE_DEVICE_TABLE(of, mma8451q_of_match);

static const struct i2c_device_id mma8451q_idtable[] = {
	{ "mma8451q", 0 },
	{ "mma8452", 0 },
	{ "mma8453", 0 },
	{ "pibrick-mma8451q", 0 },
	{}
};
MODULE_DEVICE_TABLE(i2c, mma8451q_idtable);

static struct i2c_driver mma8451q_driver = {
	.driver = {
		.name = "mma8451q",
		.of_match_table = mma8451q_of_match,
		.pm = &mma8451q_pm_ops,
	},
	.probe = mma8451q_probe,
	.remove = mma8451q_remove,
	.id_table = mma8451q_idtable,
};
module_i2c_driver(mma8451q_driver);

MODULE_AUTHOR("piBrick");
MODULE_DESCRIPTION("MMA8451Q 3-axis accelerometer driver");
MODULE_LICENSE("GPL");
