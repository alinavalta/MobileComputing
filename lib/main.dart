import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:volume/volume.dart';
import 'package:flutter_blue/flutter_blue.dart';

const backgroundTask = "listenForData";



void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  // This widget is the root of your application.



  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'eSense mute',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        // This is the theme of your application.
        //
        // Try running your application with "flutter run". You'll see the
        // application has a blue toolbar. Then, without quitting the app, try
        // changing the primarySwatch below to Colors.green and then invoke
        // "hot reload" (press "r" in the console where you ran "flutter run",
        // or simply save your changes to "hot reload" in a Flutter IDE).
        // Notice that the counter didn't reset back to zero; the application
        // is not restarted.
      ),
      home: MyHomePage(title: 'Mute your music with eSense'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  MyHomePage({Key key, this.title}) : super(key: key);

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  _MyHomePageState createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _currentVol = 0;
  Duration timeout = new Duration(seconds: 4);
  double _sliderValue = 4;
  double _thresholdValue = 2250;
  FlutterBlue flutterBlue;
  bool timerIsRunning = false;
  bool bluetoothRunning = false;
  BluetoothCharacteristic motionSenor;
  BluetoothCharacteristic startStop;
  BluetoothDevice device;
  var dataList = new List<int>();
  bool isConnection = false;

  void _incrementCounter() {
     flutterBlue = FlutterBlue.instance;
    setState((){
      isConnection = true;
      if(bluetoothRunning) {
        onStop();
      } else {
        bluetoothRunning = true;
        flutterBlue.isOn.then((isOn) {
          if(isOn) {
            flutterBlue.scan(timeout: Duration(seconds: 4))
                .listen((onScanResult)).onDone(() {
                  if(device == null) {
                    _noESenseDetected("No eSense device was found. Make sure you turned it on.");
                  }
            });
          } else {
            _noESenseDetected("Your bluetooth is off please turn it on and try again.");
          }
        });

      }
    });
  }

  Future<void> _noESenseDetected(String msg) async {
    setState(() {
      bluetoothRunning = false;
      isConnection = false;
    });
    return showDialog<void>(
      context: context,
      barrierDismissible: true, // user must tap button!
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('No connection'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text(msg),
              ],
            ),
          ),
          actions: <Widget>[
            FlatButton(
              child: Text('OK'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> onStop() async {
    if(device == null) {
      setState(() {
        bluetoothRunning = false;
        isConnection = false;
      });
      return;
    }
    flutterBlue.stopScan();
    await startStop.write([0x53, 0x16, 0x02, 0x00, 0x14]);
    motionSenor.setNotifyValue(false);
    device.disconnect().whenComplete((){
      setState((){
        bluetoothRunning = false;
        isConnection = false;
      });
      startStop = null;
      motionSenor = null;
    });
  }

  void onScanResult(ScanResult scanResult) {
      BluetoothDevice device = scanResult.device;
      if(device.name.contains("eSense")) {
        this.device = device;
        flutterBlue.stopScan();
        this.device.connect().whenComplete(() async {
          await initCharacteristics(this.device).then((value) {
            if(!value) {
              flutterBlue.scan(timeout: Duration(seconds: 4))
                  .listen((onScanResult));
            }
          });
          if (startStop != null && motionSenor != null) {
            await startSampling(startStop);
            enableNotification(motionSenor);
            motionSenor.value.listen((receiveData));
          }
        });
      }
  }

  Future<bool> initCharacteristics (BluetoothDevice device) async {
    List<BluetoothService> services = await device.discoverServices();
    bool serviceFound = false;
    services.forEach((service){
      if(service.uuid.toString().contains("0000ff06")) {
        serviceFound = true;
        service.characteristics.forEach((characteristic) {
          if (characteristic.uuid.toString().contains("0000ff08")) {
            motionSenor = characteristic;
            print("MotionSenor init");
          } else if (characteristic.uuid.toString().contains("0000ff07")) {
            startStop = characteristic;
            print("Start/Stop init");
          }
        });
      }
    });
    return serviceFound;
  }

  void enableNotification (BluetoothCharacteristic imuChar) {
    if(imuChar.isNotifying == false) {
      imuChar.setNotifyValue(true);
      print("Notification enabled");
    } else {
      print("Notification already enabled");
    }
  }

  Future<void> startSampling (BluetoothCharacteristic startStop) async {
    await startStop.write([0x53, 0x17, 0x02, 0x01, 0x14]);
    print("Samping started");
  }

  void receiveData(List<int> value) {
    if(value.length > 15){
      int yGyro = (value.elementAt(6) << 8).toSigned(16) + value.elementAt(7);
      if(dataList.length > 30) {
        dataList.removeAt(0);
      }
      dataList.add((yGyro));
      print("$yGyro" );
      if(dataList.length > 20) {
        setState(() {
          isConnection = false;
        });
        processData(dataList.getRange(dataList.length - 20, dataList.length - 1));
      }
    }
  }

  void processData(Iterable<int> data) {
    if(detectMovement(data, true) || detectMovement(data, false)) {
      print("Turned");
      startTimer();
    }
  }

  bool detectMovement(Iterable<int> data, bool left) {
    int count = 0;
    int countThreshold = 4;
    int sign = left ? 1 : -1;
    int countReset = 0;
    data.forEach((value){
      if(value* sign > 4500 - _thresholdValue) {
        count ++;
      }
      if(count >= countThreshold) {
        sign = sign*(-1);
        count = 0;
        countReset++;
      }
    });
    if(countReset >= 2 ){
      return true;
    }
    return false;
  }

  Future<void> startTimer() async {
    if(timerIsRunning) {
      return;
    }
    setState(() {
      timerIsRunning = true;
    });

    Volume.controlVolume(AudioManager.STREAM_MUSIC);
    _currentVol = await Volume.getVol;
    if(_currentVol != 0) {
      Volume.setVol(0);
      new Timer(new Duration(seconds: _sliderValue.toInt()), () {
        Volume.setVol(_currentVol);
        setState((){
          timerIsRunning = false;
        });
      });
    } else {
      setState(() {
        timerIsRunning = false;
      });
    }

  }

  Future<void> onInfo() async {
    return showDialog<void>(
      context: context,
      barrierDismissible: true, // user must tap button!
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text('Information'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text("With this app you can mute your music by turning your head left or right. \nConnect your right (if you want to use a single earbud left) eSense earbud to your phone and click on start."),
              ],
            ),
          ),
          actions: <Widget>[
            FlatButton(
              child: Text('OK'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
  }


  void onSliderChange(double value) {
    setState(() {
      _sliderValue = value.roundToDouble();
    });
  }

  void onThresholdChange(double value) {
    setState((){
      _thresholdValue = value.roundToDouble();
    });
  }


  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
        backgroundColor: Colors.indigo[900],
        actions: <Widget>[
          IconButton(
            icon : Icon(Icons.info_outline),
            onPressed: onInfo,
          )
        ],
      ),
      body: Center(
        // Center is a layout widget. It takes a single child and positions it
        // in the middle of the parent.
        child: Column(
          // Column is also a layout widget. It takes a list of children and
          // arranges them vertically. By default, it sizes itself to fit its
          // children horizontally, and tries to be as tall as its parent.
          //
          // Invoke "debug painting" (press "p" in the console, choose the
          // "Toggle Debug Paint" action from the Flutter Inspector in Android
          // Studio, or the "Toggle Debug Paint" command in Visual Studio Code)
          // to see the wireframe for each widget.
          //
          // Column has various properties to control how it sizes itself and
          // how it positions its children. Here we use mainAxisAlignment to
          // center the children vertically; the main axis here is the vertical
          // axis because Columns are vertical (the cross axis would be
          // horizontal).
          mainAxisAlignment: MainAxisAlignment.start,
          children: <Widget>[
            Card(
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      "Settings",
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 24, color: Colors.blue),
                    ),
                    SizedBox(height: 10,),
                    Text(
                        "Sensibility",
                      style: TextStyle(fontSize: 18),
                    ),
                    Slider(
                      value: _thresholdValue,
                      max: 4000,
                      min: 500,
                      onChanged: onThresholdChange,
                    ),
                    Text(
                      'Timeout: ${_sliderValue.toInt()} sec.',
                      style: TextStyle(fontSize: 18),
                    ),
                    Slider(
                      value: _sliderValue,
                      max: 30,
                      min: 1,
                      onChanged: onSliderChange,
                      label: "Timeout",
                    ),
                    ]
              ),
            ),
            Spacer (
            ),
            Visibility(
              child: CircularProgressIndicator(
                value: null,
                ),
              visible: isConnection,
            ),
            Visibility(
              child: Icon(
                timerIsRunning ? Icons.volume_off : Icons.volume_up,
                color: bluetoothRunning ? (timerIsRunning ? Colors.blue[200] : Colors.blue) : Colors.grey[200],
                size: 150.0,
                key: Key("icon"),
              ),
              visible: !isConnection,
            ),
            Spacer (
            ),
            ButtonTheme(
              minWidth: double.infinity,
              child: RaisedButton(
                onPressed: _incrementCounter,
                child: Text(
                  bluetoothRunning ? "Stop" : "Start",
                  style: TextStyle(color: Colors.white, fontSize: 24),
                ),
                color: Colors.indigo[900],
              ),
            ),
          ],
        ),
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
  }
}
